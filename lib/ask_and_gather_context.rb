def ask_and_gather_context(repo, llmc, temperature, prompt_common, max_perask_lines, max_valid_lines, reask_iter_limit)
  iters = 0
  valid_lines = 0
  reask_block = ""
  ask_block = ""
  asks = []

  prompt_reask = <<~PROMPT
  ==========================================================================================================================================================

  Now is your last chance to ask for further context! If you need more information to resolve the task at hand, please ask for it now.

  Analyze the content before the divider line to understand the context of the task at hand.

  If there is a code block for you to edit, gather all the relevant information for the edit. Make sure you have context for all the lines to be edited.

  If there is a bug to be fixed, gather all the relevant information to the bug at hand. Make sure you have context for all the lines to be fixed.

  If there is a task to be performed, gather all the relevant information to the task at hand. Make sure you have context for all the lines to be affected.

  Make sure you have the original definitions of the variables, functions, classes, and methods you are working with when needed.

  Send commands as JSON objects. Available commands:

  {
    "command": "grep-context-n",
    "pattern": "search pattern",
    "paths": ["path1", "path2"]
  }
  Description: Grep recursively for pattern in specified paths. Paths optional, defaults to ["."]

  {
    "command": "cat-context", 
    "line": 123,
    "path": "relative/path"
  }
  Description: Show context around line in file

  {
    "command": "blame-line",
    "line": 123, 
    "path": "relative/path"
  }
  Description: Show git blame for line in file

  {
    "command": "close"
  }
  Description: End context gathering when sufficient context is gathered

  All responses must be valid JSON objects matching the format above.
  When done, send {"command": "close"}

  Analyze the content carefully. Make specific, focused requests.
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
    #BUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks

    prompt_reask += <<~PROMPT


    Send a JSON command object to request more context, or {"command": "close"} if you have enough context.

    Your next command:

    PROMPT
    #puts prompt_common
    #puts prompt_reask

    response = ""
    brackets = 0
    catch :close do
      llmc.completions(
        parameters: {
          temperature: temperature,
          prompt: prompt_common + prompt_reask,
          max_tokens: 512,
          json_schema: {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": {
              "command": {
                "type": "string",
                "enum": ["grep-context-n", "cat-context", "blame-line", "close"]
              },
              "pattern": {
                "type": "string"
              },
              "paths": {
                "type": "array",
                "items": {
                  "type": "string"
                }
              },
              "line": {
                "type": "integer"
              },
              "path": {
                "type": "string"
              }
            },
            "required": ["command"]
          },
          stream: proc do |chunk, _bytesize|
            text = chunk["choices"].first["text"]
            #print text
            response += text
            begin
              JSON.parse(response)
              throw :close
            rescue JSON::ParserError
              # continue
            end
          end
        }
      )
    end
    #p command
    begin
      command = JSON.parse(response)
    rescue JSON::ParserError
      command = nil
    end
    unless command && command["command"]
      puts "N/A: Invalid JSON command format: #{response}"
      next
    end

    tool = command["command"]
    params = case tool
    when "grep-context-n"
      [command["pattern"]] + (command["paths"] || [])
    when "cat-context", "blame-line"  
      [command["line"].to_s, command["path"]].compact
    when "close"
      []
    else
      puts "N/A: Invalid command"
      next
    end

    params_str = params.join(" ")
    print "%s %s" % [tool, params_str]

    # If duplicate ask
    if asks.include?([tool, params_str])
      puts ": Duplicate"
      reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: DUPLICATE REQUEST REJECTED.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
      next
    end
    asks << [tool, params_str]

    result = ""
    case tool
    when "grep-context-n"
      files = []
      pattern = command["pattern"]
      if command["paths"].nil? || command["paths"].empty?
        command["paths"] = ["."]
      end
      command["paths"].sort.uniq.each do |param|
        if param.strip.empty?
          pattern = ""
          break
        end
        if param.start_with?("./")
          param = param[2..-1] 
        elsif param.start_with?("/")
          param = param[1..-1]
        elsif param.start_with?("a/")
          param = param[2..-1]
        elsif param.start_with?("b/")
          param = param[2..-1]
        end
        if File.exist?(File.join(repo.workdir, param))
          files << param
        elsif !Dir.glob(File.join(repo.workdir, param)).select { |file| File.directory?(file) }.empty?
          globbed_files = Dir.glob(File.join(repo.workdir, param))
          if globbed_files.empty?
            print ": Invalid file or glob pattern: #{param}"
            reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: File or glob pattern not found: #{param}\n"
            pattern = ""            
            break
          end
          globbed_files.each do |file|
            relative_path = Pathname.new(file).relative_path_from(Pathname.new(repo.workdir)).to_s
            if File.exist?(File.join(repo.workdir, relative_path))
              files << relative_path
            end
          end
        end
      end

      if files.size > max_valid_lines
        puts ": Over budget (wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available)"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Output too large. Would go over budget with such glob path, wanted #{files.size} lines, but only #{max_valid_lines - valid_lines} available.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      if files.empty?
        puts ": Invalid file or glob pattern"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Invalid file or glob pattern\n"
        next
      end
      if pattern.nil? || pattern.strip.empty?
        puts ": Invalid ask"
        next
      end
      params = [pattern] + files
      cmd = "cd #{repo.workdir} && git grep --no-color -n \"#{pattern}\" -- #{files.join(" ")}"
      git_grep_result = `#{cmd}`
      if git_grep_result.size > (max_valid_lines - valid_lines)
        puts ": Over budget (git grep has #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} lines available at all)"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Output too large, would go over budget, wanted #{git_grep_result.size} lines, but only #{max_valid_lines - valid_lines} available.\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nNothing found for pattern: \"#{pattern}\" in any of files! (files: #{files.join(" ")})\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
      line_number = command["line"]
      file = command["path"]
      
      unless line_number && file
        puts ": Missing line or path"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Missing line number or path\n"
        next
      end

      if !File.exist?(File.join(repo.workdir, file)) || !File.file?(File.join(repo.workdir, file))
        puts ": File not found or is a directory"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: File not found or is a directory: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      context = get_file_context(repo, file, [line_number], 40)
      if context.empty?
        line_count = File.read(File.join(repo.workdir, file)).split("\n").size
        puts ": Line not found"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Line not found: #{line_number}, the file only has #{line_count} lines\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      result = "\n#{file}:\n"
      result += "```\n" + context + "\n```\n"
      puts
    when "blame-line"
      line_number = command["line"]
      file = command["path"]

      unless line_number && file
        puts ": Missing line or path"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Missing line number or path\n" 
        next
      end

      if !File.exist?(File.join(repo.workdir, file))
        puts ": File not found"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: File not found: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
        next
      end
      result = `cd #{repo.workdir} && git blame -L #{line_number},#{line_number} -- #{Shellwords.escape(file)} 2>&1`
      if result.empty?
        puts ": No blame found"
        reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: No blame found for line: #{line_number} in file: #{file}\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
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
      reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\nERROR: Over budget, wanted #{result_lines} lines, but only #{max_perask_lines} available\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
    else
      valid_lines += result_lines
      ask_block += result
      reask_block += "\nCommand: #{JSON.pretty_generate(command)}\nRESULT:\n" + result + "\nBUDGET_LEFT: #{max_valid_lines - valid_lines} lines and #{reask_iter_limit - iters} asks"
    end
  end
  ask_block
end