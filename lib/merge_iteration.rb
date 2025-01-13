def merge_iteration(llmc, temperature, repo, reset_target, dst_branch_name, src_sha, sha, reask_llmc, reask_perask_lines, reask_valid_lines, reask_iter_limit, prev_result, error_context)
  # Remove commit_list loop and keep the core conflict resolution logic
  merge_result = { llm_ported: false, resolved: false, commited_as: nil, reset_target: reset_target, porting_steps: [] }
  
  begin
    commit = repo.lookup(sha)
    # Attempt cherry-pick
    repo.cherrypick(commit)
    src_sha_obj = repo.lookup(src_sha)

    # Attempt cherry-pick
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
      begin
        parent_tree = parent_commit.tree
        parent_blob = parent_tree.path(path)[:oid]
      rescue => e
        puts "Error getting parent commit for #{sha}: #{e.message}"
        puts e.backtrace
        next
      end
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

      previous_solution = ""
      if !prev_result.nil?
        prev_result[:porting_steps].each do |porting_step|
          porting_step[:resolved_mergeblocks].each_with_index do |mergeblock, index|
            if mergeblock[:sha] == sha && \
              mergeblock[:path] == path && \
              mergeblock[:mergeblock_start] == first_block_start && \
              mergeblock[:mergeblock_end] == first_block_end
              previous_solution = mergeblock[:solution]
            end
          end unless porting_step[:resolved_mergeblocks].empty?
        end

        if !error_context.empty?
          error_prompt = <<~CONTEXT

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
          error_prompt = <<~CONTEXT

          CONTEXT
        end
      end

      prompt_common_warmup = <<~PROMPT
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
      #{old_block}
      ```

      Carefully mind the current state of code we're merging this commit onto:

      ```
      #{original_block}
      ```
      PROMPT

      prompt_common = prompt_common_warmup + <<~PROMPT

      #{error_prompt}

      And finally and most importantly, this is the code block with the merge conflict you need to resolve:

      In file #{path} on lines from #{first_block_start} to #{first_block_end}:
      There is a merge conflict in the following code block:
      ```
      #{conflicted_block}
      ```

      PROMPT

      #background_warmup = Thread.new do
        warmup_kv_cache_common_prompt(llmc, prompt_common_warmup)
      #end

      puts "Gathering additional context for block in #{path} on line #{first_block_start}:"
      asked_block = ask_and_gather_context(repo, reask_llmc, temperature, prompt_common,
                                          reask_perask_lines, reask_valid_lines, reask_iter_limit)
      #puts "Asked block: #{asked_block}"

      #background_warmup.join

      prompt_mergeblock = <<~PROMPT

      Additional context for resolution of the merge conflict in file #{path} on lines from #{first_block_start} to #{first_block_end}:

      #{asked_block}
      
      To recapitulate, this is the code block with the merge conflict you need to resolve, it is in file #{path} on lines from #{first_block_start} to #{first_block_end}:

      ```
      #{conflicted_block}```

      You can now start resolving the conflict. Provide fully integrated, correctly resolved merged code block, according to the Instructions, down below:

      Merged code block:

      PROMPT
  
      puts "Resolving conflict in #{path}:"
      puts "Code block start: #{first_block_start+1}, end: #{first_block_end+1}"

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
          solution_numbered_hash[$1.to_i-1] = $2
          solution_numbered_hash[$1.to_i-1] ||= ""
        end
      end
      solution_numbered_hash = solution_numbered_hash.sort.to_h
      solution_start = solution_numbered_hash.keys.min
      solution_end = solution_numbered_hash.keys.max
    
      if solution_numbered_hash.empty? || !(solution_start <= first_block_end && first_block_start <= solution_end)
        puts "Failed - solution does not overlap with merge block"
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
        if index > first_block_end-1
          new_content << line
        end
      end
      # Write resolved file
      temp_path = "#{full_path}.tmp"
      begin
        File.open(temp_path, 'w') { |f| f.write(new_content.join("\n") + "\n") }
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
          message: "[rllm-ported] " + commit.message + "\nPorted-by: rllm\n",
          parents: [repo.head.target],
          update_ref: 'HEAD'
        })
        repo.reset(commit_oid, :hard)
        puts "Commited as #{commit_oid}"
        reset_target = repo.lookup(commit_oid).oid
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
        message: commit.message,
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
    merge_result[:llm_ported] = ported
    merge_result[:resolved] = true
    merge_result[:commited_as] = commit_oid
    merge_result[:porting_steps] = porting_steps
    merge_result[:reset_target] = reset_target

  rescue => e
    puts "Error processing commit #{sha}: #{e.message}"
    puts e.backtrace
    repo.reset(reset_target, :hard)
    exit #redo
  end
  merge_result
end
