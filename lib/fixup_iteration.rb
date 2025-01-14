def fixup_iteration(llmc, temperature, repo, sha, build_output, last_patch_str, reask_llmc, reask_perask_lines, reask_valid_lines, reask_iter_limit)
  # Strip ANSI codes, parse errors (keep existing code)
  ansi_regex = /\x1b(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~]|\][^@\x07]*[@\x07]|\x7f)/
  build_output = build_output.force_encoding('UTF-8')
  error_lines = build_output.split("\n").map { |l| l.gsub(ansi_regex, "") }
  parsed_error_lines = []
  error_files = []

  error_lines.each do |line|
    match = line.match(/^(.+):(\d+):(\d+):(.+)$/)
    next unless match
    type = case
           when match[4] =~ /error/i then "error"
          # when match[4] =~ /warning/i then "warning"
           else "unknown"
           end
    next if type == "unknown"
    parsed_error_lines << {
      file: match[1],
      line: match[2].to_i,
      column: match[3].to_i,
      type: type,
      message: match[4]
    }
    error_files << match[1]
  end
  return { success: true, changes: [] } if parsed_error_lines.empty?

  last_patch_str_numbered = ""
  if !last_patch_str.empty?
    
    max_lineno_length = last_patch_str.split("\n").size.to_s.size
    last_patch_str.split("\n").each_with_index do |line, index|
      last_patch_str_numbered += "%#{max_lineno_length}d %s\n" % [index + 1, line]
    end
  end
  last_patch_str_numbered = last_patch_str_numbered.force_encoding('UTF-8')

  initial_prompt = ""
  # First pass - let LLM gather context about errors
  initial_prompt += <<~PROMPT
  You are tasked to fix build errors after a failed merge attempt.

  Given these build errors and warnings:

  #{parsed_error_lines.map { |e| "#{e[:file]}:#{e[:line]}:#{e[:column]}: #{e[:message]}" }.join("\n")}

  You can ask for more context before deciding what to edit.
  PROMPT

  #if !last_patch_str_numbered.empty?
  #  initial_prompt += <<~PROMPT
  #
  #  This is a next iteration of the fixup process on top of new merge results.
#
  #  During the previous merge iteration, we have tried to fix the errors and warnings of the previous build. In case you find it useful, here is the last patch that was applied:
  #  
  #  ```
  #  #{last_patch_str_numbered}
  #  ```  
  #  PROMPT
  #end

  initial_prompt += <<~PROMPT

  Examine the errors and ask for any additional context you need.
  
  PROMPT

  puts "Gathering additional context for #{error_files.uniq.size} files with #{parsed_error_lines.size} errors"
  # Get context using existing function
  ask_block = ask_and_gather_context(
    repo,
    reask_llmc, 
    temperature,
    initial_prompt,
    reask_perask_lines,
    reask_valid_lines,
    reask_iter_limit
  )

  # Second pass - get edit locations with context
  edit_suggestions_prompt = <<~PROMPT
  You are tasked to fix build errors after a failed merge attempt.

  Given these build errors:

  Errors:
  #{parsed_error_lines.map { |e| "#{e[:file]}:#{e[:line]}:#{e[:column]}: #{e[:message]}" }.join("\n")}

  Additional context gathered for your consideration:
  #{ask_block}
  
  Please specify which files and line ranges you need to edit to fix these issues.
  
  Valid format examples:
  
  Example 1:

  EDIT: relative_path_to_file:start_line-end_line # rationale for edit

  Example 2:

  EDIT: relative_path_to_file:start_line # rationale for edit

  Thus, the format is strictly following the pattern:

  EDIT: relative_path_to_file:start_line[-end_line] # rationale for edit

  Each EDIT suggestion line must start with "EDIT:" and contain the relative path to the file, the line number or range of lines to edit, and the rationale for the edit.

  You can only specify one range per file. If you need to edit multiple ranges in the same file, just enlarge the range to include all lines you need to edit.

  Your response will be used to guide the editing process for each individual file location.

  In your response, interject the EDIT lines with any additional comments or context you find useful.

  End your response with END_RESPONSE.

  Your response:

  PROMPT

  warmup_kv_cache_common_prompt(llmc, edit_suggestions_prompt)

  edit_suggestions = []
  edit_suggestions_response = ""
  while edit_suggestions.empty?
    # Get edit locations
    edit_suggestions = []
    edit_suggestions_response = ""
    catch(:close) do
      llmc.completions(
        parameters: {
          temperature: temperature,
          prompt: edit_suggestions_prompt,
          max_tokens: 2048,
          stream: proc do |chunk, _bytesize|
            edit_suggestions_response += chunk["choices"].first["text"]
            print chunk["choices"].first["text"]
            if edit_suggestions_response.include?("END_RESPONSE")
              throw :close
            end
          end
        }
      )
    end
    puts
    edit_suggestions_response = edit_suggestions_response.force_encoding('UTF-8')

    edit_suggestions_response.split("\n").each do |line|
      # Match EDIT: relative_path_to_file:start_line-end_line # rationale for edit
      # or EDIT: relative_path_to_file:start_line # rationale for edit
      if line =~ /^\s*\**\s*\**\s*EDIT\s*\**:\s*([^:]+):(\d+(?:-\d+)?)\s*#\s*(.*)$/
        file = $1.strip
        range = $2.strip
        rationale = $3.strip
        
        if range =~ /(\d+)-(\d+)/
          edit_suggestions << {
            file: file,
            start_line: $1.to_i - 1,
            end_line: $2.to_i - 1,
            rationale: rationale
          }
        else
          # Single line edit
          line_num = range.to_i
          edit_suggestions << {
            file: file,
            start_line: line_num - 1,
            end_line: line_num - 1,
            rationale: rationale
          }
        end
        puts "Found edit location: #{file}:#{range} # #{rationale}"
      end
    end
  end

  # Process each edit location
  edit_suggestions.each do |location|
    file = location[:file]
    file = file[2..-1] if file.start_with?("./")

    p location

    file_path = File.join(repo.workdir, file)
    next unless File.exist?(file_path)

    puts "Processing edit for #{file} lines #{location[:start_line] + 1}-#{location[:end_line] + 1}"

    puts "Gathering additional context for edit #{file} lines #{location[:start_line] + 1}-#{location[:end_line] + 1}"

    initial_prompt = <<~PROMPT
    You are tasked to fix build errors after a failed merge attempt.

    Given these build errors and warnings:

    #{parsed_error_lines.map { |e| "#{e[:file]}:#{e[:line]}:#{e[:column]}: #{e[:message]}" }.join("\n")}
    
    You are editing #{file} lines #{location[:start_line] + 1}-#{location[:end_line] + 1}.

    The rationale for this edit is: #{location[:rationale]}.

    PROMPT

    # Get additional context like in merge_iteration
    ask_block = ask_and_gather_context(
      repo,
      reask_llmc,
      temperature,
      initial_prompt,
      reask_perask_lines,
      reask_valid_lines,
      reask_iter_limit
    )

    # Get file content and prepare context block
    file_content = File.read(file_path).split("\n")
    context_around = 25
    start_line = [0, location[:start_line] - context_around].max
    end_line = [file_content.size - 1, location[:end_line] + context_around].min
    
    edit_block = ""
    max_lineno_length = file_content.size.to_s.size
    (start_line..end_line).each do |i|
      edit_block += "%#{max_lineno_length}d %s\n" % [i + 1, file_content[i]]
    end

    puts "Blaming commit for #{file}:#{location[:start_line]}"
    blamed_commit_oid = ""
    blamed_commit_msg_first_line = ""
    blamed_commit_str_numbered = "<not available>"
    blamed_commit = nil
    begin
      full_path = File.join(repo.workdir, file)
      blame_line = `cd #{repo.workdir}; git blame -l -L #{location[:start_line]},#{location[:start_line]} #{file}`.split("\n")
      p blame_line
      blamed_commit_oid = blame_line.last.split(" ")[0]
      if blamed_commit_oid.start_with?("^")
        blamed_commit_oid = ""
      #blamed_commit_oid = blamed_commit_oid[0..-2] if blamed_commit_oid.end_with?("~")
      #first_commit_in_repo_oid = `cd #{repo.workdir}; git rev-list --max-parents=0 HEAD`.strip
      #if blamed_commit_oid == first_commit_in_repo_oid
        blamed_commit_oid = ""
        blamed_commit_str_numbered = "<first commit in repository, too large to display>"
        puts "Blamed commit: #{blamed_commit_oid}"
        blamed_commit = repo.lookup(blamed_commit_oid)
      end
    rescue => e
      #puts "Failed to get blamed commit for #{file}:#{location[:start_line]}: #{e.message}"
      #puts e.backtrace
    end
    unless blamed_commit.nil?
      blamed_commit_msg_first_line = blamed_commit.message.split("\n").first
      blamed_commit_str = "```\n"
      blamed_commit_str += "commit #{sha}\n"
      blamed_commit_str += "Author: #{blamed_commit.author[:name]} <#{blamed_commit.author[:email]}>\n"
      blamed_commit_str += "Date: #{Time.at(blamed_commit.time)}\n"
      blamed_commit_str += "\n"
      blamed_commit_str += blamed_commit.message
      blamed_commit_str += "\n"
      blamed_commit_str += "\n"
      blamed_commit_str += blamed_commit.diff(blamed_commit.parents.first).patch
      blamed_commit_str += "\n"
      blamed_commit_str += "```\n"
      blamed_commit_str_lines = blamed_commit_str.split("\n")
      blamed_commit_str_numbered = ""
      max_lineno_length = blamed_commit_str_lines.size.to_s.size
      blamed_commit_str_lines.each_with_index do |line, index|
        blamed_commit_str_numbered += "%#{max_lineno_length}d %s\n" % [index + 1, line]
      end
      blamed_commit_str_numbered = blamed_commit_str_numbered.force_encoding('UTF-8')        
    end
    puts "Blamed commit str length: #{blamed_commit_str_numbered.split("\n").size}"

    edit_prompt_cache = <<~PROMPT
    You are tasked to fix build errors after a failed merge attempt.

    These are the these build errors we have:
    ========================
    #{build_output}
    ========================

    Here is the additional context for this edit:
    #{ask_block}

    Considering this additional context, you can diverge from the original edit suggestion if needed.

    For full context, read through the commit that introduced the error, which we would like to fix to get it working properly.
    
    The original version of the commit before porting it onto this state of codebase is:

    #{blamed_commit_str_numbered}

    We have already picked what we're going to edit and why. Here are the overall edit suggestions:

    #{edit_suggestions_response}
    
    PROMPT

    warmup_kv_cache_common_prompt(llmc, edit_prompt_cache)

    edit_prompt = edit_prompt_cache + <<~PROMPT
    We're solving the errors of #{file} now.
    
    We're editing lines #{location[:start_line] + 1}-#{location[:end_line] + 1}.

    The original rationale for this edit: #{location[:rationale]}.

    And finally, here is the code block from #{file} for you to edit:
    ```
    #{edit_block}
    ```

    Please provide the edited version of this code block.
    
    IMPORTANT: Instructions for editing:

    1. Start with "```".
    2. You must begin with the first line of the code block.
    3. Produce complete integrated version of the edited code block.
    4. By prefixing each line with the line number, ensure your edited code lands in the correct location.
    5. If you need to remove a line, just skip it completely.
    6. You are forbidden from adding comments or annotations to the code block.
    7. End with "```".

    Example format:
    ```
    123 def method
    124   fixed_code_here
    125 end
    126
    128 def example2
    ```

    Your response:
    PROMPT

    # Get and apply edit suggestion using existing numbered line merge logic
    response = ""
    catch(:close) do
      llmc.completions(
        parameters: {
          temperature: temperature,
          prompt: edit_prompt,
          max_tokens: 512,
          stream: proc do |chunk, _bytesize|
            response += chunk["choices"].first["text"]
            print chunk["choices"].first["text"]

            block_marker_count = response.split("\n").select { |line| line.start_with?("```") }.size
            
            if block_marker_count >= 2
              throw :close
            end
          end
        }
      )
    end

    lines = response.split("\n").reverse
    solution = ""
    in_block = false
    lines.each do |line|
      if line.start_with?("```")
        in_block = !in_block
      elsif in_block
        solution = line + "\n" + solution
      end
    end
    solution_array = solution.split("\n")
    solution_numbered_hash = {}
    solution_array.each_with_index do |line, index|
      if line =~ /^\s{0,5}(\d{1,6}) (.*)$/
        solution_numbered_hash[$1.to_i] = $2
        solution_numbered_hash[$1.to_i] ||= ""
      end
    end
    solution_numbered_hash = solution_numbered_hash.sort.to_h
    solution_start = solution_numbered_hash.keys.min
    solution_end = solution_numbered_hash.keys.max
    
    if solution_numbered_hash.empty?
      puts "Failed - solution empty, response was: \n#{response}"
      redo
    end

    # Validate line numbers:
    # Test overlap
    p location
    puts "Solution start: #{solution_start}, end: #{solution_end}"
    unless solution_start <= location[:end_line] && location[:start_line] <= solution_end
      puts "Failed - solution does not overlap with location"
      redo
    end
    


    #if error
    #  puts "Failed - solution has missing line numbers"
    #  next
    #end

    # Read current file content
    file_path = File.join(repo.workdir, file)
    file_content = File.read(file_path).split("\n")

    # Generate new content
    new_content = []
    
    # Add lines before fix
    file_content.each_with_index do |line, index|
      index += 1
      if index <= solution_start
        new_content << line
      end
    end

    # Add fixed lines
    solution_numbered_hash.each do |line_number, line|
      new_content << line
    end

    # Add remaining lines
    file_content.each_with_index do |line, index|
      index += 1
      if index > solution_end 
        new_content << line
      end
    end

    begin
      File.open(file_path, 'w') { |f| f.write(new_content.join("\n") + "\n") }
      repo.index.add(file)
      puts "Successfully applied changes to #{file}"
      true
    rescue => e
      puts "Failed to apply changes to #{file}: #{e.message}"
      puts e.backtrace
      redo
    end
  end

  puts "fixup_iteration completed"
  { success: true, changes: [] }
end