def merge_iteration(llmc, repo, src_commit, commit_list, dst_branch_name, error_context = "", prev_results = {})
  merge_results = {}

  # Delete dst branch if exists, create new one from src_commit and then cherrypick commits
  repo.reset(repo.lookup(src_commit).oid, :hard)
  repo.checkout(repo.lookup(src_commit).oid)

  begin
    repo.branches.delete(dst_branch_name)
  rescue Rugged::ReferenceError
  end

  commit_obj = repo.lookup(src_commit)
  repo.branches.create(dst_branch_name, commit_obj.oid)
  repo.checkout("refs/heads/#{dst_branch_name}")

  n_commits = commit_list.size
  n_commit = 0
  commit_list.each do |sha|
    merge_results[sha] = { llm_ported: false, resolved: false, commited_as: nil, porting_steps: [] }
    n_commit += 1
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
          porting_steps << porting_steps
        end
        porting_step = { reason: nil, resolved_mergeblocks: [] }
        conflict = repo.index.conflicts.first
        path = conflict[:theirs][:path]
        full_path = File.join(repo.workdir, path)

        puts "Resolving conflicts in #{path}"

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

        puts "\Pending merge blocks: #{pending_merge_blocks}\n\n"

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

        conflicted_content = ""
        file_array.each_with_index do |line, index|
          max_digits = first_block_end.to_s.length
          if index >= first_block_start && index <= first_block_end
            conflicted_content += "%#{max_digits}d %s\n" % [index+1, line]
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
        
        unless prev_results.empty?
          previous_solution = ""
          prev_results.each do |sha, result|
            result[:porting_steps].each do |step|
              step[:resolved_mergeblocks].each do |mergeblock|
                if mergeblock[:sha] == sha && \
                   mergeblock[:path] == path && \
                   mergeblock[:mergeblock_start] == first_block_start && \
                   mergeblock[:mergeblock_end] == first_block_end
                  previous_solution = mergeblock[:solution]
                end
              end
            end
          end

          error_context = <<~CONTEXT

          Note, you have already attempted to merge the code, but you have failed.
        
          Following is the output of the build process from the your previous failed attempt:
        
          ```
          #{error_context}
          ```

          We also provide you with your previous attempt to merge the code in this file at this offset:
          ```
          #{previous_solution}
          ```

          CONTEXT
        end

        prompt = <<~PROMPT
        You are resolving a Git merge conflict.

        Carefully read these instructions, then the original commit and the code block with a conflict to be merged.

        Instructions:
        - Your task is to resolve the conflict in the code block by merging the code from the original commit and the code from the branch we're merging on top of.
        - Resolving the merge conflict in the code block provided below the original commit.
        - Be mindful of the full context.
        - Do only what is relevant for resolving the merge conflict.
        - Resolve conflicts in full spirit of the original commit.
        - If the commit introduces a new feature, ensure that the feature is preserved in the final code.
        - If the commit rearranges or refactors code, ensure that the final code is refactored in the same way.
        - Correctly number the lines in the solved code block to match their new positions in the target file.
        - Don't insert any  comments into the resolved merge code block itself.

        The original commit:

        ```
        #{commit_details}
        ```
        #{error_context}

        In file: #{path}

        This is the code block with the conflict to be solved:

        ```
        #{conflicted_content}
        ```

        Provide a fully integrated resolved merged code block with resolved conflicts below:

        PROMPT
    
        puts "Resolving conflict in #{path}:"
        puts conflicted_content
        #puts prompt
        puts "LLM response:"
        porting_step[:prompt] = prompt

        response = ""
        catch(:close) do
          llmc.completions(
            parameters: {
              temperature: 0.7,
              prompt: prompt,
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
        
          if solution_start != first_block_start
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

          porting_step[:resolved_mergeblocks] << {
            sha: sha,
            path: path,
            mergeblock: conflicted_content,
            mergeblock_start: first_block_start,
            mergeblock_end: first_block_end,
            solution: solution
          }


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
      raise
    end
  end

  merge_results
end
