def apply_suggested_changes(repo, file, line_number, solution)
  # Get current file content
  full_path = File.join(repo.workdir, file)
  return false unless File.exist?(full_path)
  
  file_array = File.read(full_path).split("\n")
  solution_array = solution.split("\n")
  solution_hash = {}
  
  # Parse numbered solution lines
  solution_array.each do |line|
    if line =~ /^(\s{0,5}\d{1,6}) (.*)$/
      solution_hash[$1.to_i-1] = $2
    end
  end
  
  return false if solution_hash.empty?
  
  # Find solution boundaries
  solution_start = solution_hash.keys.min 
  solution_end = solution_hash.keys.max
  
  # Validate line numbers match
  return false if solution_start != line_number
  
  # Create new content 
  new_content = []
  
  # Keep content before change
  file_array.each_with_index do |line, index|
    break if index >= solution_start
    new_content << line
  end
  
  # Insert solution
  solution_hash.each do |line_number, line|
    new_content << line
  end
  
  # Keep remaining content
  file_array.each_with_index do |line, index|
    next if index <= solution_end
    new_content << line
  end
  
  # Write updated file
  temp_path = "#{full_path}.tmp"
  begin
    File.open(temp_path, 'w') { |f| f.write(new_content.join("\n")) }
    FileUtils.mv(temp_path, full_path)
    return true
  rescue => e
    FileUtils.rm(temp_path) if File.exist?(temp_path)
    puts "Error applying changes: #{e}"
    return false
  end
end

def fixup_iteration(llmc, temperature, repo, build_output, reask_llmc, reask_perask_lines, reask_valid_lines, reask_iter_limit)
  # 1) Strip ANSI codes, parse errors
  ansi_regex = /\x1b(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~]|\][^@\x07]*[@\x07]|\x7f)/
  error_lines = build_output.split("\n").map { |l| l.gsub(ansi_regex, "") }
  parsed_error_lines = []
  error_files = []

  error_lines.each do |line|
    match = line.match(/^(.+):(\d+):(\d+):(.+)$/)
    next unless match
    type = case
           when match[4] =~ /error/i then "error"
           when match[4] =~ /warning/i then "warning"
           else "unknown"
           end
    parsed_error_lines << {
      file: match[1],
      line: match[2].to_i,
      column: match[3].to_i,
      type: type,
      message: match[4]
    }
    error_files << match[1]
  end
  return true if parsed_error_lines.empty?

  # 2) Gather around-error context
  error_files_context = {}
  error_files.uniq.each do |file|
    file_path = File.join(repo.workdir, file)
    next unless File.exist?(file_path)
    lines_arr = File.read(file_path).split("\n")
    relevant = parsed_error_lines.select { |err| err[:file] == file }
    error_context_around = 8

    relevant.each do |err|
      start_line = [0, err[:line] - error_context_around - 1].max
      end_line   = [lines_arr.size - 1, err[:line] + error_context_around - 1].min
      slice = lines_arr[start_line..end_line]
      (start_line..end_line).each_with_index do |lineno, idx|
        error_files_context[file] ||= {}
        error_files_context[file][lineno] = slice[idx]
      end
    end
    error_files_context[file] = error_files_context[file].sort.to_h
  end

  # 3) For each error line, blame + gather context like in merge_iteration
  error_files_context.each do |file, lines_h|
    lines_h.each do |lineno, content|
      blame = []
      begin
        blame = repo.blame(file, new_start_line: lineno + 1, new_end_line: lineno + 1)
      rescue => e
        puts "Blame error #{e}"
      end

      culprit_commit = blame[0][:orig_commit] rescue nil
      culprit_subject = culprit_commit ? culprit_commit.message.to_s.split("\n").first : "<no commit>"
      puts "\nFile: #{file}, line #{lineno + 1}, introduced by commit: #{culprit_subject}"

      ask_block = ask_and_gather_context(
        repo,
        reask_llmc,
        temperature,
        "", # prompt_common
        file,
        reask_perask_lines,
        reask_valid_lines,
        reask_iter_limit
      )

      # Prepare LLM prompt with blame + user context
      prompt = <<~PROMPT
        We have an issue at #{file}:#{lineno + 1}, introduced by:
        Commit subject: #{culprit_subject}

        Additional context requested:
        #{ask_block}

        Please propose a fix referencing line #{lineno + 1}.
      PROMPT

      response = ""
      catch(:close) do
        llmc.completions(
          parameters: {
            temperature: temperature,
            prompt: prompt,
            max_tokens: 512,
            stream: proc do |chunk, _bytesize|
              response += chunk["choices"].first["text"]
              print chunk["choices"].first["text"]
              
              if response.include?("```") && response.split("```").size >= 2
                throw :close
              end
            end
          }
        )
      end

      # Extract code block from response
      blocks = response.split("\n").reverse
      solution = ""
      in_block = false
      blocks.each do |line|
        if line.start_with?("```")
          in_block = !in_block
        elsif in_block
          solution = line + "\n" + solution
        end
      end

      if solution && apply_suggested_changes(repo, file, lineno, solution)
        puts "Successfully applied changes to #{file}"
      else
        puts "Failed to apply changes to #{file}"
      end
    end
  end

  puts "fixup_iteration completed"
  false
end