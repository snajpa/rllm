def attempt_llm_fix(llmc, error_output, repo, patches)
  max_attempts = 3
  attempts = 0

  while attempts < max_attempts
    errors = parse_build_errors(error_output)
    return true if errors.empty?

    puts "\n=== Fix Attempt #{attempts + 1}/#{max_attempts} ==="
    puts "Found #{errors.length} compilation errors to fix"

    file_errors = errors.group_by { |e| e[:file] }
    fixed_any = false

    file_errors.each do |file, file_errors|
      puts "\nProcessing file: #{file}"
      puts "#{file_errors.length} errors found"
      
      patch = find_related_patch(file, patches)
      unless patch
        puts "No related patch found, skipping..."
        next
      end

      context = get_file_context(repo, file, file_errors)
      prompt = create_fix_prompt(context, patch, file_errors)

      puts "\nRequesting LLM fix suggestion..."
      puts "Context size: #{context.size} lines"
      
      fixes = {}
      current_file = nil
      current_code = []
      
      # Stream LLM response
      catch(:close) do
        llmc.completions(
          parameters: {
            prompt: prompt,
            max_tokens: 128000,
            stream: true
          }
        ) do |chunk|
          if chunk.dig("choices", 0, "finish_reason") == "stop"
            if current_file
              fixes[current_file] = current_code.join("\n")
            end
          else
            content = chunk.dig("choices", 0, "text").to_s
            print content
            
            content.each_line do |line|
              if line =~ /^FILE_PATH:\s*(.+)$/
                if current_file
                  fixes[current_file] = current_code.join("\n")
                  current_code = []
                end
                current_file = $1.strip
              elsif current_file && line.strip !~ /^```/
                current_code << line
              end
            end
          end
        end
      end
      puts

      next if fixes.empty?

      puts "\nApplying fixes to #{fixes.keys.size} files..."
      fixes.each do |fix_file, content|
        puts "- #{fix_file}"
      end
      
      apply_fixes(repo, fixes)
      fixed_any = true
    end

    if fixed_any
      puts "\nCommitting fixes and rebuilding..."
      repo.index.write
      
      force_push(repo.workdir, dst_remote_name, dst_branch_name)
      
      build_result = ssh_build_iteration("172.16.106.12", "root", ssh_options, 
                                       false, dst_remote_name, dst_branch_name,
                                       "~/linux-rllm", 64)
      
      if build_result[:results].last[:exit_status] == 0
        puts "\nBuild successful after fixes!"
        return true
      end
      
      error_output = build_result[:results].last[:output_lines].join("\n")
    end

    attempts += 1
    puts "\nFix attempt #{attempts} failed..." if attempts < max_attempts
  end

  false
end

def parse_build_errors(build_output)
  errors = []
  build_output.each_line do |line|
    if line =~ /^(.+):(\d+):(\d+):\s+(error|warning):\s+(.+)$/
      errors << {
        file: $1,
        line: $2.to_i,
        column: $3.to_i,
        type: $4,
        message: $5.strip
      }
    end
  end
  errors
end

def find_related_patch(file, patches)
  patches.find { |p| p.file == file }
end

def get_file_context(repo, file, errors)
  content = File.read(File.join(repo.workdir, file))
  lines = content.lines

  context = {}
  errors.each do |error|
    start_line = [error[:line] - 10, 0].max
    end_line = [error[:line] + 10, lines.length].min
    
    context[error[:line]] = {
      code: lines[start_line..end_line].join,
      error: error[:message]
    }
  end
  context
end

def create_fix_prompt(context, patch, errors)
  <<~PROMPT
    I need help fixing compilation errors in a Linux kernel patch.
    
    Original patch:
    #{patch}
    
    Compilation errors:
    #{errors.map { |e| "#{e[:file]}:#{e[:line]}: #{e[:message]}" }.join("\n")}
    
    Relevant code context:
    #{context.map { |line, ctx| "Around line #{line}:\n#{ctx[:code]}\nError: #{ctx[:error]}\n" }.join("\n")}
    
    Please provide fixes in the following format:
    FILE_PATH: path/to/file
    ```c
    // New code block
    ```
  PROMPT
end

def get_llm_fixes(llmc, prompt)
  response = llmc.complete(prompt)
  parse_fixes_from_response(response)
end

def parse_fixes_from_response(response)
  fixes = {}
  current_file = nil
  current_code = []

  response.each_line do |line|
    if line =~ /^FILE_PATH:\s*(.+)$/
      if current_file
        fixes[current_file] = current_code.join("\n")
        current_code = []
      end
      current_file = $1.strip
    elsif current_file && line.strip =~ /^```/
      next
    elsif current_file
      current_code << line
    end
  end

  fixes[current_file] = current_code.join("\n") if current_file
  fixes
end

def apply_fixes(repo, fixes)
  fixes.each do |file, content|
    full_path = File.join(repo.workdir, file)
    file_array = File.read(full_path).split("\n")
    solution_array = content.split("\n")
    solution_numbered_hash = {}
    
    solution_array.each_with_index do |line, index|
      if line =~ /^(\s{0,5}\d{1,6}) (.*)$/
        solution_numbered_hash[$1.to_i-1] = $2
      end
    end
    
    solution_start = solution_numbered_hash.keys.min
    solution_end = solution_numbered_hash.keys.max
    new_content = []

    # Arrive at solution - same as merge_iteration
    file_array.each_with_index do |line, index|
      if index >= solution_end
        break
      end
      if index < solution_start
        new_content << line
      end
    end
    
    # Fill in solution
    solution_numbered_hash.each do |line_number, line|
      new_content << line
    end
    
    # Fill in rest of file
    file_array.each_with_index do |line, index|
      if index > solution_end
        new_content << line
      end
    end
    
    # Write resolved file with temp file safety
    temp_path = "#{full_path}.tmp"
    begin
      File.open(temp_path, 'w') { |f| f.write(new_content.join("\n")) }
      FileUtils.mv(temp_path, full_path)
    rescue => e
      FileUtils.rm(temp_path) if File.exist?(temp_path)
      raise e
    end
  end
end

def rebuild_project
  # Reuse existing ssh_build_iteration method
  b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                         dst_remote_name, dst_branch_name, "~/linux-rllm", 64)
  
  {
    success: b[:results].last[:exit_status] == 0,
    output: b[:results].last[:output_lines].join("\n")
  }
end