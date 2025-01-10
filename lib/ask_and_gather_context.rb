def ask_and_gather_context(repo, llmc, temperature, prompt_common, max_perask_lines, max_valid_lines, reask_iter_limit)
  iters = 0
  valid_lines = 0
  reask_block = ""
  ask_block = ""
  asks = []
  puts "Gathering additional context"
  while valid_lines < max_valid_lines
    iters += 1
    if iters > reask_iter_limit
      puts "Reached reask limit"
      break
    end

    max_digits_l = max_valid_lines.to_s.length
    max_digits_i = reask_iter_limit.to_s.length
    print "%#{max_digits_i}d/%#{max_digits_i}d iters %#{max_digits_l}d/%#{max_digits_l}d lines, ask: " % [iters, reask_iter_limit, valid_lines, max_valid_lines]

    prompt_reask = <<~PROMPT
    ============================================================================================

    Now is your last chance to ask for further context! If you need more information to resolve the task at hand, please ask for it now.

    When you're done, please type ASK: close to finish asking for context.

    The format is an ask per line, per line format is ASK: <tool> <parameter1> [<parameter2> ...]. Available tools are:
    - Grep with context:
      - Syntax:
          ASK: grep-context-n <pattern> <relative_path_or_glob_pattern1> [<relative_path_or_glob_pattern2> ...]
      - Description: grep recursively for a pattern in path or glob pattern - use relative paths, either a files or directories, . for the whole repo
      - Mandatory parameters: pattern, relative_path_or_glob_pattern1
    - Cat with context:
      - Syntax:
          ASK: cat-context <line_number> <relative_path>      
      - Description: show the context around a line in a file
      - Mandatory parameters: line_number, relative_path
    - Blame line:
      - Syntax:
          ASK: blame-line <line_number> <relative_path>
      - Description: show the git blame for a line in a file
      - Mandatory parameters: line_number, relative_path
    - Close the context gathering:
      - Syntax:
          ASK: close
      - Description: end the context gathering when sufficient context is gathered

    The ask should be in this format:
    ASK: <tool> <parameter1> [<parameter2> ...]

    When you have sufficient context, type ASK: close to finish asking for context.

    Gather the most relevant information to the task at hand by giving asks that are specific and focused rather than broad and general.

    PROMPT

    if ask_block.empty?
      prompt_reask += <<~PROMPT
      
      ---------------------
      No previous asks from you currently, here are examples for you to understand the required format:

      ASK: grep-rn hello
      RESULT:
      
      In file1.txt:
      ```
      1 hello world
      ```
      
      LINES_BUDGET_LEFT: 10
      
      ASK: close
      RESULT:
      Done asking for more context
      
      Examples end here.

      ---------------------

      PROMPT
    else
      prompt_reask += <<~PROMPT
      
      ---------------------
      Your previous asks:
      
      #{reask_block}
      
      ---------------------

      PROMPT
    end
    prompt_reask += <<~PROMPT

    LINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}

    Please respond in the format ASK: <tool> <parameter1> [<parameter2> ...] to ask for more context.

    Pick the most relevant tool to ask for the context you need to resolve the task at hand.
  
    ---------------------
    Next ask:
    
    PROMPT
  #puts prompt_common
    #puts prompt_reask

    ask = ""
    ask_match = nil
    catch(:close) do
      llmc.completions(
        parameters: {
          temperature: temperature,
          prompt: prompt_common + prompt_reask,
          max_tokens: 128,
          stream: proc do |chunk, _bytesize|
            ask += chunk["choices"].first["text"]
            #print chunk["choices"].first["text"]

            if ask =~ /\s*ASK:.*\n.*$/
              throw :close
            end
          end
        }
      )
    end
    ask.split("\n").each_with_index do |line, index|
      ask_match = line.match(/^\s*ASK: (grep-context-n|cat-context|blame-line|close)\s?(.+)?$/)
      if !ask_match.nil?
        break
      end
    end
    if ask_match.nil?
      #puts "Invalid ask format:\n#{ask}\n"
      puts "N/A: Invalid ask format"
      #reask_block += "\nInvalid ask format, syntax is: ASK: <tool> <parameter1> [<parameter2> ...]\n"
      next
    end
    tool, params_str = ask_match.captures
    params_str ||= ""
    params = []
    params_str.split(/\s(?=(?:[^"]|"[^"]*")*$)/).each do |param|
      if param.start_with?('"') && param.end_with?('"')
        params << param[1..-2]
      else
        params << param
      end
    end

    print "%s %s" % [tool, params_str]

    # If duplicate ask
    if asks.include?([tool, params_str])
      puts ": Duplicate ask"
      reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nDuplicate ask\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
      next
    end
    asks << [tool, params_str]

    result = ""
    case tool
    when "grep-context-n"
      files = []
      pattern = params[0]
      params[1..-1].each do |param|
        next if param.strip.empty?
        param = param[1..-1] if param.start_with?("/")
        if File.exist?(File.join(repo.workdir, param))
          files << param
        elsif globbed_files = Dir.glob(File.join(repo.workdir, param)).select { |file| File.file?(file) }
          globbed_files.each do |file|
            relative_path = Pathname.new(file).relative_path_from(Pathname.new(repo.workdir)).to_s
            files << relative_path
          end
        else
          puts ": Invalid file or glob pattern: #{param}"
          #reask_block += "\ASK: #{tool} #{params.join(" ")}\nRESULT:\nInvalid ask, file or glob pattern not found: #{param}\n"
          next
        end
      end
      if files.size > max_valid_lines
        puts ": Over budget (wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available)"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nOver budget with the glob path, wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available.\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      if files.empty?
        files = ["."]  # default to whole repo
      end
      if pattern.strip.empty?
        puts ": Invalid ask"
        #reask_block += "\ASK: #{tool} #{params.join(" ")}\nRESULT:\nInvalid ask, syntax is ASK: grep-context-n <pattern> <file1> [<file2> ...]\n"
        next
      end
      params = [pattern] + files
      cmd = "cd #{repo.workdir} && git grep --no-color -n \"#{pattern}\" -- #{files.join(" ")}"
      git_grep_result = `#{cmd}`
      if git_grep_result.size > (max_valid_lines - valid_lines)
        puts ": Over budget (git grep has #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} available)"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nOver budget, wanted #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} available.\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      filelines = {}
      git_grep_result.each_line do |line|
        match = line.force_encoding("UTF-8").match(/^(.+):(\d+):(.+)$/)
        if match
          file = match[1]
          line_number = match[2].to_i
          filelines[file] ||= []
          filelines[file] << line_number
        end
      end
      if filelines.empty?
        puts ": No matches found"
        #puts "Files: #{files}"
        #puts "Pattern: #{pattern}"
        #puts "Result: #{git_grep_result}"
        #puts "Command: #{cmd}"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nNo matches found for pattern: #{pattern} in files: #{files.join(" ")}\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      filelines.each do |file, linenumbers|
        next if linenumbers.empty?
        context = get_file_context(repo, file, linenumbers, 8)
        result += "\n#{file}:\n"
        result += "```\n" + context + "\n```\n"
      end
      puts
    when "cat-context"
      file = ""
      begin
        line_number = params[0].to_i
        params[1..-1].each do |param|
          if param.strip.empty?
            file = "."
            break
          end
          file = param
          break if File.exist?(File.join(repo.workdir, file))
        end
      rescue
        puts ": Invalid ask"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nInvalid ask, syntax is ASK: cat-context <line_number> <relative_path>\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      if file.empty?
        puts ": Path not given"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nPath not given\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      # if doesn't exist or is not a file
      if !File.exist?(File.join(repo.workdir, file)) || !File.file?(File.join(repo.workdir, file))
        puts ": File not found or is a directory"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nFile not found or is a directory: #{file}\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      context = get_file_context(repo, file, [line_number], 40)
      if context.empty?
        puts ": Line not found"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nLine not found: #{line_number}\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      result = "\n#{file}:\n"
      result += "```\n" + context + "\n```\n"
      puts
    when "blame-line"
      begin
        line_number = params[0].to_i
        file = params[1]
        if file.nil?
          puts ": Path not given"
          reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nPath not given\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
          next
        end
        if !File.exist?(File.join(repo.workdir, file))
          puts ": File not found"
          reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nFile not found: #{file}\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
          next
        end
        result = `cd #{repo.workdir} && git blame -L #{line_number},#{line_number} -- #{Shellwords.escape(file)} 2>&1`
      rescue
        puts ": Invalid ask"
        next
      end
      if result.empty?
        puts ": No blame found"
        reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nNo blame found for line: #{line_number} in file: #{file}\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
        next
      end
      result = "\n```\n#{result}```\n"
      puts
    when "close"
      puts
      break
    end
    result_lines = result.split("\n").size
    if result_lines > max_perask_lines 
      reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\nOver budget, wanted #{result_lines} lines, but only #{max_perask_lines} available\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
    else
      valid_lines += result_lines
      ask_block += result
      reask_block += "\nASK: #{tool} #{params.join(" ")}\nRESULT:\n" + result + "\nLINES_BUDGET_LEFT: #{max_valid_lines - valid_lines}\n"
    end
  end
  ask_block
end