def attempt_llm_fix(build_output, repo, patches)
  max_attempts = 3
  attempts = 0

  while attempts < max_attempts
    # Extract error information
    errors = parse_build_errors(build_output)
    return true if errors.empty?

    # Group errors by file
    file_errors = errors.group_by { |e| e[:file] }

    file_errors.each do |file, errors|
      # Find related patch
      patch = find_related_patch(file, patches)
      next unless patch

      # Gather context
      context = get_file_context(repo, file, errors)

      # Create LLM prompt
      prompt = create_fix_prompt(context, patch, errors)

      # Get LLM suggestion
      fixes = get_llm_fixes(prompt)

      # Apply fixes
      apply_fixes(repo, fixes)
    end

    # Rebuild and check
    build_result = rebuild_project
    return true if build_result[:success]

    attempts += 1
    build_output = build_result[:output]
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

def get_llm_fixes(prompt)
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
    File.write(full_path, content)
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