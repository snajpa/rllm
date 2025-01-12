def ask_and_gather_context(repo, llmc, temperature, prompt_common, max_perask_lines, max_valid_lines, reask_iter_limit)
  iters = 0
  valid_lines = 0
  reask_block = ""
  ask_block = ""
  asks = []

  prompt_reask = <<~PROMPT
  ============================================================================================

  Now is your last chance to ask for further context! If you need more information to resolve the task at hand, please ask for it now.

  When you're done, please type ASK: close to finish the session.

  The format is an ask per line, per line format is ASK: <tool> <parameter1> [<parameter2> ...]. Available tools are:
  - Grep with added context:
    - Syntax:
        ASK: grep-context-n "<pattern>" <relative_path_or_glob_path1> [<relative_path_or_glob_path2> ...]
    - Description: grep recursively for a pattern.
    - Instructions for use: Put the pattern in quotes properly. Use paths relative to the root of the repository, either a files or directories, . for the whole repo, can use a glob pattern
    - Mandatory parameters: pattern, relative_path_or_glob_path1
  - Cat with added context:
    - Syntax:
        ASK: cat-context <line_number> <relative_path>      
    - Description: show the context around a line in a file.
    - Instructions for use: Use the line number and the path relative to the root of the repository.
    - Mandatory parameters: line_number, relative_path
  - Blame line:
    - Syntax:
        ASK: blame-line <line_number> <relative_path>
    - Description: show the git blame for a line in a file.
    - Instructions for use: Use the line number and the path relative to the root of the repository.
    - Mandatory parameters: line_number, relative_path
  - Close the context gathering:
    - Syntax:
        ASK: close
    - Description: end the context gathering when sufficient context is gathered.
    - Instructions for use: Use this when you have enough context to confidently resolve the task at hand.

  The ask should be in this format:
  ASK: <tool> <parameter1> [<parameter2> ...]

  When you have sufficient context, type ASK: close to finish the session.

  Analyze the content before the divider line to understand the context of the task at hand.

  If there is a code block for you to edit, gather all the relevant information for the edit. Make sure you have context for all the lines to be edited.
  If there is a bug to be fixed, gather all the relevant information to the bug at hand. Make sure you have context for all the lines to be fixed.
  If there is a task to be performed, gather all the relevant information to the task at hand. Make sure you have context for all the lines to be affected.

  Gather all the relevant information to the task at hand by giving asks that are specific and focused rather than broad and general.

  PROMPT

  warmup_kv_cache_common_prompt(llmc, prompt_common + prompt_reask)
  
  while valid_lines < max_valid_lines
    iters += 1
    if iters > reask_iter_limit
      puts "Reached reask limit"
      break
    end

    max_digits_l = max_valid_lines.to_s.length
    max_digits_i = reask_iter_limit.to_s.length
    print "%#{max_digits_i}d/%#{max_digits_i}d iters %#{max_digits_l}d/%#{max_digits_l}d lines, ask: " % [iters, reask_iter_limit, valid_lines, max_valid_lines]

    if ask_block.empty?
      prompt_reask += <<~PROMPT
      
      Your previous asks with their results:

      ASK: grep-rn hello
      RESULT:
      
      In file1.txt:
      ```
      1 hello world
      ```
    
      BUDGET_LEFT: 100 lines and 10 asks      

      PROMPT
    else
      #prompt_reask_v0 = <<~PROMPT
      #
      #Your previous asks with their results:
      ##{reask_block}
      #
      #Currently, you have already asked for the following:
      ##{asks.map { |tool, params_str| "ASK: #{tool} #{params_str}" }.join("\n")}
      #
      #Which lead to the following gathered context:
      #
      ##{ask_block}
      #
      #PROMPT
      prompt_reask += <<~PROMPT

      #{ask_block}

      PROMPT
    end
    prompt_reask += <<~PROMPT

    BUDGET_LEFT: #{max_valid_lines - valid_lines}

    Pick the most relevant tool to ask for the context you need to resolve the task at hand, or close the context gathering if you have enough context using ASK: close.

    Please respond in the format ASK: <tool> <parameter1> [<parameter2> ...].
  
    Your next ASK:

    PROMPT
    puts prompt_common
    puts prompt_reask

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
            print chunk["choices"].first["text"]

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
    params_str.split(/\s+(?=(?:[^"]|"[^"]*")*$)/).each do |param|
      if param.start_with?('"') && param.end_with?('"')
        params << param[1..-2]
      else
        params << param
      end
    end

    print "%s %s" % [tool, params_str]

    # If duplicate ask
    if asks.include?([tool, params_str])
      puts ": Dupla"
      #iters -= 1
      reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: DUPLICATE REQUEST REJECTED.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
      next
    end
    asks << [tool, params_str]

    result = ""
    case tool
    when "grep-context-n"
      files = []
      pattern = params[0]
      params[1..-1].each do |param|
        if param.strip.empty?
          pattern = ""
          break
        end
        param = param[1..-1] if param.start_with?("/")
        if File.exist?(File.join(repo.workdir, param))
          files << param
        elsif !Dir.glob(File.join(repo.workdir, param)).select { |file| File.directory?(file) }.empty?
          globbed_files = Dir.glob(File.join(repo.workdir, param))
          if globbed_files.empty?
            print ": Invalid file or glob pattern, eh.: #{param}"
            reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: File or glob pattern not found: #{param}\n"
            pattern = ""            
            break
          end
          globbed_files.each do |file|
            relative_path = Pathname.new(file).relative_path_from(Pathname.new(repo.workdir)).to_s
            if File.exist?(File.join(repo.workdir, relative_path))
              #puts "\n: Adding globbed path: #{relative_path}"
              files << relative_path
            else
              puts "\n: Invalid file or glob pattern - SHOULD NOT GET HERE EVER: #{relative_path}"
            end
          end
        else
          print ": Not file or glob: #{param}"
          reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: File or glob pattern not found: #{param}\n"
          pattern = ""
          break
        end
      end
      if files.size > max_valid_lines
        puts ": Over budget (wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available)"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Output too large. Would go over budget with such glob path, wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      if files.empty?
        files = ["."]  # default to whole repo
      end
      if pattern.strip.empty?
        puts ": Invalid ask"
        #reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR:Invalid ask\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      params = [pattern] + files
      cmd = "cd #{repo.workdir} && git grep --no-color -n \"#{pattern}\" -- #{files.join(" ")}"
      git_grep_result = `#{cmd}`
      if git_grep_result.size > (max_valid_lines - valid_lines)
        puts ": Over budget (git grep has #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} lines available at all)"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Output too large, would go over budget, wanted #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} available.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nNothing found for pattern: \"#{pattern}\" in any of files! (files: #{files.join(" ")})\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        ask_block += "\nNo match for pattern: \"#{pattern}\" in any of checked files - files checked: #{files.join(" ")})."
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
          file = param
          break if File.exist?(File.join(repo.workdir, file))
        end
      rescue
        puts ": Invalid ask"
        #reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Invalid ask, syntax is ASK: cat-context <line_number> <relative_path>\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      if file.empty?
        puts ": Path not given"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Path not given\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      # if doesn't exist or is not a file
      if !File.exist?(File.join(repo.workdir, file)) || !File.file?(File.join(repo.workdir, file))
        puts ": File not found or is a directory"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: File not found or is a directory: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      context = get_file_context(repo, file, [line_number], 40)
      if context.empty?
        line_count = File.read(File.join(repo.workdir, file)).split("\n").size
        puts ": Line not found"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Line not found: #{line_number}, the file only has #{line_count} lines\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
          reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Path not given\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
          next
        end
        if !File.exist?(File.join(repo.workdir, file))
          puts ": File not found"
          reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: File not found: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
          next
        end
        result = `cd #{repo.workdir} && git blame -L #{line_number},#{line_number} -- #{Shellwords.escape(file)} 2>&1`
      rescue
        puts ": Invalid ask"
        next
      end
      if result.empty?
        puts ": No blame found"
        reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: No blame found for line: #{line_number} in file: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
      reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\nERROR: Over budget, wanted #{result_lines} lines, but only #{max_perask_lines} available\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
    else
      valid_lines += result_lines
      ask_block += result
      reask_block += "\nASK: #{tool} #{params_str}\nRESULT:\n" + result + "\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
    end
  end
  ask_block
end