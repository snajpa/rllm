def merge_iteration(llmc, temperature, repo, src_commit, commit_list, dst_branch_name, reask_llmc, reask_perask_lines, reask_valid_lines, reask_iter_limit, build_output = "", prev_results = {})
  merge_results = {}
  src_commit_obj = repo.lookup(src_commit)

  # Prepare data if this is a continuation
  puts "Preparing data for merge iteration"

  error_lines = build_output.split("\n")
  parsed_error_lines = []
  error_files = []
  puts "Preparing error context" unless error_lines.empty?
  error_lines.each do |line|
    # Ah, line might include terminal escape codes, let's strip them
    ansi_regex = /\x1b(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~]|\][^@\x07]*[@\x07]|\x7f)/
    line = line.gsub(ansi_regex, "")
    match = line.match(/^(.+):(\d+):(\d+):(.+)$/)
    p match

    if match
      type = ""
      if match[4] =~ /error/i
        type = "error"
      elsif match[4] =~ /warning/i
        type = "warning"
      else
        type = "unknown"
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
  end
  puts "Error files:"
  p error_files

  error_files_context_h = {}
  error_context_around = 8
  error_files.uniq.each do |file|
    puts "Processing for file: #{file}"
    next unless File.exist?(File.join(repo.workdir, file))
    error_file_lines = File.read(File.join(repo.workdir, file)).split("\n")
    # Select context around error line + error line
    parsed_error_lines.each do |error_line|
      if error_line[:file] == file
        start_line = [0, error_line[:line] - error_context_around].max
        end_line = [error_file_lines.size - 1, error_line[:line] + error_context_around].min
        
        error_files_context_h[file] ||= {}
        error_file_lines[start_line..end_line].each_with_index do |line, index|
          error_files_context_h[file][start_line + index] = line
        end
      end
    end
    # it's a Hash of lines and we need to sort it by line number
    error_files_context_h[file] = error_files_context_h[file].sort.to_h
  end
  puts "Error files context:"
  p error_files_context_h

  # Now we get the first line of commit message for each line for each file
  #blamed_error_files_context_h = {}
  #error_files_context_h.each do |file, context_h|
  #  puts "Blaming for file: #{file}"
  #  context_h.each do |line_number, line|
  #    blame = repo.blame(file, new_start_line: line_number + 1, new_end_line: line_number + 1)
  #    blamed_error_files_context_h[file] ||= {}
  #    blamed_error_files_context_h[file][line_number] = blame[0][:orig_commit].message.split("\n").first
  #  end
  #end
  #puts "Blamed error files context:"
  #p blamed_error_files_context_h
  # End of data preparation

  # Delete dst branch if exists, create new one from src_commit and then cherrypick commits
  repo.reset(src_commit_obj.oid, :hard)
  repo.checkout(src_commit_obj.oid)

  begin
    repo.branches.delete(dst_branch_name)
  rescue Rugged::ReferenceError
  end

  repo.branches.create(dst_branch_name, src_commit_obj.oid)
  repo.checkout("refs/heads/#{dst_branch_name}")
  reset_target = src_commit_obj.oid

  n_commits = commit_list.size
  n_commit = 0
  commit_list.each do |sha|
    merge_results[sha] = { llm_ported: false, resolved: false, commited_as: nil, porting_steps: [] }
    n_commit = commit_list.index(sha) + 1
    commit = repo.lookup(sha)
    puts "\nProcessing commit #{n_commit}/#{n_commits}: #{sha[0..7]} - #{commit.message.split("\n").first}"
    begin
      # Attempt cherry-pick
      repo.cherrypick(commit)
      ported = false
      porting_step = {}
      porting_steps = []
      pending_merge_blocks = 1

      while repo.index.conflicts?
        unless porting_step.empty?
          porting_steps << porting_step
        end
        porting_step = { reason: nil, resolved_mergeblocks: [] }
        conflict = repo.index.conflicts.first
        path = conflict[:theirs][:path]
        puts "Working on #{path}:"
        full_path = File.join(repo.workdir, path)

        # Process file content and get solution
        file_content = File.read(full_path) rescue ""

        file_array = file_content.split("\n")
        labeled_lines = {}
        in_merge_block_ours = false
        in_merge_block_theirs = false
        pending_merge_blocks = 0

        file_array.each_with_index do |line, index|
          entry = {:line => line, :index => index}
          increment = false
          if line.start_with?("<<<<<<<")
            in_merge_block_ours = true
            in_merge_block_theirs = false
          elsif line.start_with?("=======")
            in_merge_block_ours = false
            in_merge_block_theirs = true
          elsif line.start_with?(">>>>>>>")
            increment = true
          end

          if in_merge_block_ours
            entry[:merge] = true
            entry[:merge_id] = pending_merge_blocks
            entry[:merge_ours] = true
          elsif in_merge_block_theirs
            entry[:merge] = true
            entry[:merge_id] = pending_merge_blocks
            entry[:merge_theirs] = true
          end

          labeled_lines[index] = entry
          if increment
            in_merge_block_ours = false
            in_merge_block_theirs = false
            pending_merge_blocks += 1
          end
        end

        puts "Pending merge blocks: #{pending_merge_blocks}"

        context_lines_after = 8
        context_lines_before = 8
        
        first_block = labeled_lines.select { |k, v| v[:merge_id] == 0 }

        porting_step[:path] = path
        porting_step[:pending_merge_blocks] = pending_merge_blocks

        if first_block.empty?
          puts "No merge blocks found in #{path}, possibly file is deleted, staging anyway"
          exit # TODO: think about this
          File.unlink(full_path) rescue nil
          repo.index.remove(path) rescue nil
          porting_step[:reason] = :no_merge_blocks
          next
        end

        first_block_start = [0, first_block.keys.min - context_lines_before].max
        first_block_end = [file_array.size - 1, first_block.keys.max + context_lines_after].min
        porting_step[:first_block_start] = first_block_start
        porting_step[:first_block_end] = first_block_end

        original_block = ""
        # Get the file content from the immediate parent commit
        parent_commit = commit.parents.first
        parent_tree = parent_commit.tree
        parent_blob = parent_tree.path(path)[:oid]
        if parent_blob
          parent_content = repo.lookup(parent_blob).content
          parent_content_array = parent_content.split("\n")
          max_digits = parent_content_array.size.to_s.length
          parent_content_array.each_with_index do |line, index|
            if index >= first_block_start && index <= first_block_end
              original_block += "%#{max_digits}d %s\n" % [index+1, line]
            end
          end
        end

        old_block = ""
        old_tree = commit.tree
        old_blob = old_tree.path(path)[:oid]
        if old_blob
          old_content = repo.lookup(old_blob).content
          old_content_array = old_content.split("\n")
          max_digits = old_content_array.size.to_s.length
          old_content_array.each_with_index do |line, index|
            if index >= first_block_start && index <= first_block_end
              old_block += "%#{max_digits}d %s\n" % [index+1, line]
            end
          end
        end

        conflicted_block = ""
        file_array.each_with_index do |line, index|
          max_digits = first_block_end.to_s.length
          if index >= first_block_start && index <= first_block_end
            conflicted_block += "%#{max_digits}d %s\n" % [index+1, line]
          end
        end

        commit_diff = repo.diff(commit.parents.first, commit).patch.to_s
        commit_details = "commit #{commit.oid}\n"  # Start with commit header
        commit_details += "Author: #{commit.author[:name]} <#{commit.author[:email]}>\n"
        commit_details += "Date:   #{commit.author[:time]}\n\n"
        commit_details += "    " + commit.message.gsub("\n", "\n    ") + "\n"  # Indent message
        commit_details += commit_diff

        commit_details = commit_details.split("\n")
        max_digits = commit_details.size.to_s.length
        commit_details = commit_details.each_with_index.map { |line, index| 
          "%#{max_digits}d %s" % [index + 1, line]
        }.join("\n")
              
        this_file_errors = parsed_error_lines.select { |error| error[:file] == path }
        previous_solution = ""
        if !prev_results.empty? &&
          prev_results.each do |sha, result|
            result[:porting_steps].each do |porting_step|
              porting_step[:resolved_mergeblocks].each_with_index do |mergeblock, index|
                if mergeblock[:sha] == sha && \
                   mergeblock[:path] == path && \
                   mergeblock[:mergeblock_start] == first_block_start && \
                   mergeblock[:mergeblock_end] == first_block_end
                  previous_solution = mergeblock[:solution]
                end
              end unless porting_step[:resolved_mergeblocks].empty?
            end
          end

          if this_file_errors.size > 0
            error_context = <<~CONTEXT

            Following is the output of the build process from the your previous failed attempt:

            ```
            #{error_context}
            ```

            We also provide you with your previous attempt to merge the code in this file at this offset:
            ```
            #{previous_solution}
            ```

            CONTEXT
          else
            error_context = <<~CONTEXT

            CONTEXT
          end
        end

        prompt_common = <<~PROMPT
        You are resolving a Git merge conflict.

        Carefully read these instructions, then the original commit and the code block with a conflict to be merged.

        Task description:
        - Your task is to resolve the conflict in the code block by merging the code from the original commit and the code from the branch we're merging on top of.

        Instructions:
        - Resolving the merge conflict in the code block provided below the original commit.
        - Be mindful of the full context.
        - Do only what is relevant for resolving the merge conflict.
        - Resolve conflicts in full spirit of the original commit.
        - If the commit introduces a new feature, ensure that the feature is preserved in the final code.
        - If the commit rearranges or refactors code, ensure that the final code is refactored in the same way.
        - Correctly number the lines in the solved code block to match their new positions in the target file.

        Constraints:
        - You are forbidden to insert any comments into the resolved merge code block itself.

        This is the full commit we're now merging:

        ```
        #{commit_details}
        ```

        For reference, this is the state of the code the commit works on:

        ```
        #{old_block}```
  
        Carefully mind the current state of code we're merging this commit onto:

        ```
        #{original_block}```

        #{error_context}
        To the conflict you're going to solve - it is in file: #{path}

        And finally and most importantly, this is the code block with the merge conflict you need to resolve:

        ```
        #{conflicted_block}```

        PROMPT

        asked_block = ask_and_gather_context(repo, reask_llmc, temperature, prompt_common,
                                             reask_perask_lines, reask_valid_lines, reask_iter_limit)
        #puts "Asked block: #{asked_block}"

        prompt_mergeblock = <<~PROMPT
        This is the additional context you asked for:

        #{asked_block}
        
        To recapitulate, this is the code block with the merge conflict you need to resolve:

        ```
        #{conflicted_block}```

        You can now start resolving the conflict. Provide fully integrated resolved merged code block below.

        ================================

        Merged code block:

        PROMPT
    
        puts "Resolving conflict in #{path}:"

        #puts prompt_common
        #puts prompt_mergeblock
        #puts conflicted_block
        
        puts "LLM response:"
        porting_step[:prompt] = prompt_mergeblock

        response = ""
        catch(:close) do
          llmc.completions(
            parameters: {
              temperature: temperature,
              prompt: prompt_common + prompt_mergeblock,
              max_tokens: 128000,
              stream: proc do |chunk, _bytesize|
                response += chunk["choices"].first["text"]
                print chunk["choices"].first["text"] # stream to console

                block_marker_count = response.split("\n").select { |line| line.start_with?("```") }.size
                
                if block_marker_count == 2
                  response += "\n"
                  throw :close 
                end
              end
            }
          )
        end
        puts
        porting_step[:response] = response

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

        if solution
          solution_array = solution.split("\n")
          solution_numbered_hash = {}
        
          solution_array.each_with_index do |line, index|
            if line =~ /^(\s{0,5}\d{1,6}) (.*)$/
              solution_numbered_hash[$1.to_i-1] = $2
            end
          end
          solution_start = solution_numbered_hash.keys.min
          solution_end = solution_numbered_hash.keys.max
        
          if solution_start != first_block_start && this_file_errors.size == 0
            puts "Solution start (#{solution_start}) does not match first block start (#{first_block_start})"
            porting_step[:reason] = :solution_start_mismatch
            next
          end

          error = false
          solution_end.downto(solution_start) do |line_number|
            if !solution_numbered_hash.has_key?(line_number)
              puts "Missing line #{line_number}"
              error = true
            end
          end
          if error
            porting_step[:reason] = :solution_missing_lines
            next
          end

          new_content = []

          # Arrive at solution
          file_array.each_with_index do |line, index|
            if index >= first_block_end
              break
            end
            if index < first_block_start
              new_content << line
            end
          end
          # Fill in solution
          solution_numbered_hash.each do |line_number, line|
            new_content << line
          end
          # Fill in rest of file
          file_array.each_with_index do |line, index|
            if index > first_block_end
              new_content << line
            end
          end
          # Write resolved file
          temp_path = "#{full_path}.tmp"
          begin
            File.open(temp_path, 'w') { |f| f.write(new_content.join("\n")) }
            FileUtils.mv(temp_path, full_path)
          rescue => e
            FileUtils.rm(temp_path) if File.exist?(temp_path)
            raise e
          end

          pending_merge_blocks -= 1
          ported = true
          step = {
            sha: sha,
            path: path,
            mergeblock: conflicted_block,
            mergeblock_start: first_block_start,
            mergeblock_end: first_block_end,
            solution: solution
          }
          porting_step[:resolved_mergeblocks] << step


          # Stage resolved file and mark as resolved
          current_full_mode = repo.head.target.tree.path(path)[:filemode]
          repo.index.add(path: path, oid: Rugged::Blob.from_workdir(repo, path), mode: current_full_mode)
          if pending_merge_blocks > 0
            next
          else
            repo.index.conflict_remove(path)
            repo.index.write
          end

          # Verify index is clean before creating tree
          if !repo.index.conflicts?
            commit_oid = Rugged::Commit.create(repo, {
              tree: repo.index.write_tree(repo),
              author: commit.author,
              committer: commit.committer,
              message: commit.message + " [ported]",
              parents: [repo.head.target],
              update_ref: 'HEAD'
            })
            repo.reset(commit_oid, :hard)
            puts "Commited as #{commit_oid}"
            reset_target = repo.lookup(commit_oid).oid
          end
        end
        unless porting_step.empty?
          porting_steps << porting_step
        end
      end

      # Handle non-conflict case
      if !ported && !repo.index.conflicts?
        commit_oid = Rugged::Commit.create(repo, {
          tree: repo.index.write_tree(repo),
          author: commit.author,
          committer: commit.committer,
          message: commit.message + " [rllm-ported]",
          parents: [repo.head.target],
          update_ref: 'HEAD'
        })
        repo.reset(commit_oid, :hard)
        puts "Commited as #{commit_oid}"
        reset_target = repo.lookup(commit_oid).oid
      else
        # Debug conflicted files before write_tree
        repo.index.conflicts.each do |conflict|
          puts "Conflict in: #{conflict[:ancestor]&.fetch(:path) || conflict[:ours]&.fetch(:path) || conflict[:theirs]&.fetch(:path)}"
          puts "  Ancestor: #{conflict[:ancestor]&.fetch(:oid)}"
          puts "  Ours: #{conflict[:ours]&.fetch(:oid)}" 
          puts "  Theirs: #{conflict[:theirs]&.fetch(:oid)}"
        end
      end
      if commit_oid.nil?
        puts "Failed to commit #{sha}"
        exit
      end       
      merge_results[sha][:llm_ported] = ported
      merge_results[sha][:resolved] = true
      merge_results[sha][:commited_as] = commit_oid
      merge_results[sha][:porting_steps] = porting_steps

    rescue => e
      puts "Error processing commit #{sha}: #{e.message}"
      puts e.backtrace
      repo.reset(reset_target, :hard)
      exit #redo
    end
  end

  merge_results
end
