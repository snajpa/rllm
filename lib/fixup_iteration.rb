def fixup_iteration(llmc, temperature, repo, build_output, last_patch_str, reask_llmc, reask_perask_lines, reask_valid_lines, reask_iter_limit)
  # Strip ANSI codes, parse errors (keep existing code)
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

  last_patch_str_numbered = ""
  if !last_patch_str.empty?
    
    max_lineno_length = last_patch_str.split("\n").size.to_s.size
    last_patch_str.split("\n").each_with_index do |line, index|
      last_patch_str_numbered += "%#{max_lineno_length}d %s\n" % [index + 1, line]
    end
  end

  initial_prompt = ""
  # First pass - let LLM gather context about errors
  initial_prompt += <<~PROMPT
  You are tasked to fix build errors after a failed merge attempt.

  Given these build errors and warnings:

  #{parsed_error_lines.map { |e| "#{e[:file]}:#{e[:line]}:#{e[:column]}: #{e[:message]}" }.join("\n")}

  You can ask for more context before deciding what to edit.
  PROMPT

  if !last_patch_str_numbered.empty?
    initial_prompt += <<~PROMPT
  
    This is a next iteration of the fixup process on top of new merge results.

    During the previous merge iteration, we have tried to fix the errors and warnings of the previous build. In case you find it useful, here is the last patch that was applied:
    
    ```
    #{last_patch_str_numbered}
    ```  
    PROMPT
  end
  initial_prompt += <<~PROMPT

  Examine the errors and ask for any additional context you need.
  
  PROMPT

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
  edit_location_prompt = <<~PROMPT
  You are tasked to fix build errors after a failed merge attempt.

  Given these build errors and context:

  Errors:
  #{parsed_error_lines.map { |e| "#{e[:file]}:#{e[:line]}:#{e[:column]}: #{e[:message]}" }.join("\n")}

  Context gathered:
  #{ask_block}

  PROMPT

  if !last_patch_str_numbered.empty?
    edit_location_prompt += <<~PROMPT
  
    This is a next iteration of the fixup process on top of new merge results.

    During the previous merge iteration, we have tried to fix the errors and warnings of the previous build. In case you find it useful, here is the last patch that was applied:
    
    ```
    #{last_patch_str_numbered}
    ```  
    PROMPT
  end

  edit_location_prompt += <<~PROMPT
  
  Please specify which files and line ranges you need to edit to fix these issues.
  
  Valid format examples:
  
  Example 1:

  EDIT: relative_path_to_file:start_line-end_line # rationale for edit

  Example 2:

  EDIT: relative_path_to_file:start_line # rationale for edit

  Thus, the format is strictly following the pattern:

  EDIT: relative_path_to_file:start_line[-end_line] # rationale for edit

  You can only specify one range per file. If you need to edit multiple ranges in the same file, please specify them separately.

  Which files and line ranges do you need to edit?

  Your response:

  PROMPT

  edit_locations = []
  while edit_locations.empty?
    # Get edit locations
    edit_locations = []
    response = ""
    catch(:close) do
      llmc.completions(
        parameters: {
          temperature: temperature,
          prompt: edit_location_prompt,
          max_tokens: 512,
          stream: proc do |chunk, _bytesize|
            response += chunk["choices"].first["text"]
            print chunk["choices"].first["text"]
          end
        }
      )
    end

    response.split("\n").each do |line|
      # Match EDIT: relative_path_to_file:start_line-end_line # rationale for edit
      # or EDIT: relative_path_to_file:start_line # rationale for edit
      if line =~ /^EDIT\**:\s*([^:]+):(\d+(?:-\d+)?)\s*#\s*(.*)$/
        file = $1.strip
        range = $2.strip
        rationale = $3.strip
        
        if range =~ /(\d+)-(\d+)/
          edit_locations << {
            file: file,
            start_line: $1.to_i - 1,
            end_line: $2.to_i - 1,
            rationale: rationale
          }
        else
          # Single line edit
          line_num = range.to_i
          edit_locations << {
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
  edit_locations.each do |location|
    file = location[:file]
    file_path = File.join(repo.workdir, file)
    next unless File.exist?(file_path)

    puts "Processing edit for #{file} lines #{location[:start_line] + 1}-#{location[:end_line] + 1}"

    # Get context like in merge_iteration
    ask_block = ask_and_gather_context(
      repo,
      reask_llmc,
      temperature,
      file,
      reask_perask_lines,
      reask_valid_lines,
      reask_iter_limit
    )

    # Get file content and prepare context block
    file_content = File.read(file_path).split("\n")
    context_around = 25
    start_line = [0, location[:start_line] - context_around].max
    end_line = [file_content.size - 1, location[:end_line] + context_around].min
    
    context_block = ""
    (start_line..end_line).each do |i|
      context_block += "%d %s\n" % [i + 1, file_content[i]]
    end

    edit_prompt = <<~PROMPT
    We need to edit #{file} lines #{location[:start_line] + 1}-#{location[:end_line] + 1}.
    The rationale for this edit is: #{location[:rationale]}.

    Additional context gathered:
    #{ask_block}
    PROMPT

    if !last_patch_str_numbered.empty?
      edit_prompt += <<~PROMPT
    
      This is a next iteration of the fixup process on top of new merge results.

      During the previous merge iteration, we have tried to fix the errors and warnings of the previous build. In case you find it useful, here is the last patch that was applied:
      
      ```
      #{last_patch_str_numbered}
      ```  
      PROMPT
    end

    edit_location_prompt += <<~PROMPT

    Here is the current code block with line numbers:
    ```
    #{context_block}
    ```

    Please provide the edited version of this code block.
    IMPORTANT: Your response must:
    1. Start with "```"
    2. Be complete integrated version of the edited code block
    3. Preserve line numbers exactly as shown
    4. End with "```

    Example format:
    ```
    123 def method
    124   fixed_code_here
    125 end
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
            
            if response.include?("```") && response.split("```").size >= 3
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
    solution_numbered_hash = {}

    blocks.each do |line|
      if line.start_with?("```")
        in_block = !in_block
      elsif in_block
        # Parse numbered lines (e.g. "  123 code")
        if line =~ /^(\s{0,5}\d{1,6}) (.*)$/
          solution_numbered_hash[$1.to_i-1] = $2
        else
          solution += line + "\n"
        end
      end
    end

    if !solution_numbered_hash.empty?
      solution_start = solution_numbered_hash.keys.min
      solution_end = solution_numbered_hash.keys.max

      # Validate line numbers
      error = false
      solution_end.downto(solution_start) do |line_number|
        if !solution_numbered_hash.has_key?(line_number)
          puts "Missing line #{line_number}"
          error = true
        end
      end
      
      if error
        puts "Failed - solution has missing line numbers"
        next
      end

      # Read current file content
      file_path = File.join(repo.workdir, file)
      file_content = File.read(file_path).split("\n")

      # Generate new content
      new_content = []
      
      # Add lines before fix
      file_content.each_with_index do |line, index|
        if index >= solution_end
          break
        end
        if index < solution_start 
          new_content << line
        end
      end

      # Add fixed lines
      solution_numbered_hash.each do |line_number, line|
        new_content << line
      end

      # Add remaining lines
      file_content.each_with_index do |line, index|
        if index > solution_end
          new_content << line
        end
      end

      begin
        File.open(file_path, 'w') { |f| f.write(new_content.join("\n")) }
        puts "Successfully applied changes to #{file}"
        true
      rescue => e
        puts "Failed to apply changes to #{file}: #{e.message}"
        puts e.backtrace
        false
      end
    else
      puts "Failed - no valid numbered lines found in solution"
      false
    end
  end

  puts "fixup_iteration completed"
  false
end