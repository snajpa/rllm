#!/usr/bin/env ruby

require 'rubygems'
require 'rugged'
require 'optparse'
require 'uri'
require 'net/http'
require 'json'

require 'openai'

LLAMA_API_ENDPOINT = 'http://localhost:8081'
LOG_FILE = 'rllm.log'

options = {}

repo_dir = '/home/snajpa/linux'
src_commit = '0bc21e701a6f' # 6.13-rc5
cherrypick_commit_range = '319addc2ad90..68eb45c3ef9e'
#cherrypick_commit_range = 'd3e69f8ab5df..c0dcbf44ec68'
dst_branch_name = 'vpsadminos-6.13'

OpenAI.configure do |config|
  config.access_token = ""
  config.log_errors = true
  config.uri_base = LLAMA_API_ENDPOINT
  config.request_timeout = 900
end

OptionParser.new do |opts|
  opts.banner = "Usage: rllm.rb [options]"
end.parse!

repo = Rugged::Repository.new(repo_dir)

llmc = OpenAI::Client.new

range = cherrypick_commit_range.split('..')
walker = Rugged::Walker.new(repo)
walker.push(repo.lookup(range[1]).oid)
walker.hide(repo.lookup(range[0]).oid)
commit_list = walker.map(&:oid).reverse

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

def build_merge_prompt(conflicted_content, commit_details, path)
  <<~PROMPT
    You are resolving a Git merge conflict.

    Carefully read these instructions, then the original commit and the code block with a conflict to be merged.

    Your task is to resolve the conflict in the code block by merging the code from the original commit and the code from the branch we're merging on top of.

    Finish the merge by resolving the conflict in the code block:
    - Be mindful of the full context of the commit and the code block.
    - Resolve conflicts in the block in full spirit of the original commit.
    - If the commit introduces a new feature, ensure that the feature is preserved in the final code.
    - If the commit rearranges or refactors code, ensure that the final code block is refactored in the same way.
    - Prepend the lines with correct line numbers in your response.

    Note:
    - If you intend to comment on your reasoning or approach, please do so before you open the code block.
    - You are forbidden to comment your actions in the code block itself.
    - Consider the possibility, that the properly merged block might belong to a different file:
      - When the original commit rearranges code and we're merging on top of a changed version of such code, we need to put the block to its new place as well.
      - If this is the case, please provide the full path to the file in the response.
      - Use a dedicated line prepended with FILE_PATH: followed by the full path.
    
    The original commit:

    ```
    #{commit_details}
    ```

    This is the code block with the conflict to be solved:

    FILE_PATH: `#{path}`
    ```
    #{conflicted_content}
    ```

    Provide a fully integrated solved merged code block below.

  PROMPT
end

tree = nil
commit_list.each do |sha|
  commit = repo.lookup(sha)
  puts
  puts "Attempting to cherry-pick commit #{sha}"
  puts commit.message.split("\n").first

  begin
    repo.cherrypick(commit)
    
    ported = false
    merge_blocks = 1
    while repo.index.conflicts? && merge_blocks > 0
      conflict = repo.index.conflicts.first
      path = conflict[:theirs][:path]
      puts "Conflict detected in #{path}, resolving..."
      
      full_path = File.join(repo.workdir, path)
      file_content = File.read(full_path) rescue ""

      file_array = file_content.split("\n")
      labeled_lines = {}
      in_merge_block_ours = false
      in_merge_block_theirs = false
      merge_blocks = 0

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
          entry[:merge_id] = merge_blocks
          entry[:merge_ours] = true
        elsif in_merge_block_theirs
          entry[:merge] = true
          entry[:merge_id] = merge_blocks
          entry[:merge_theirs] = true
        end

        labeled_lines[index] = entry
        if increment
          in_merge_block_ours = false
          in_merge_block_theirs = false
          merge_blocks += 1
        end
      end

      context_lines_after = 8
      context_lines_before = 8
      
      first_block = labeled_lines.select { |k, v| v[:merge_id] == 0 }
      #p labeled_lines
      #p first_block
      if first_block.empty?
        puts "No merge blocks found in #{path}, possibly file is deleted, staging anyway"
        File.unlink(full_path) rescue nil
        repo.index.remove(path) rescue nil
        next
      end

      first_block_start = [0, first_block.keys.min - context_lines_before].max
      first_block_end = [file_array.size - 1, first_block.keys.max + context_lines_after].min

      conflicted_content = ""
      file_array.each_with_index do |line, index|
        max_digits = first_block_end.to_s.length
        if index >= first_block_start && index <= first_block_end
          conflicted_content += "%#{max_digits}d %s\n" % [index+1, line]
        end
      end

      #commit_message = commit.message.split("\n").each_with_index.map { |line, index| "%4d %s" % [index + 1, line] }.join("\n")
      #commit_diff = repo.diff(commit.parents.first, commit, paths: [path]).patch.to_s.split("\n").each_with_index.map { |line, index| "%4d %s" % [index + 1, line] }.join("\n")
      #commit_diff = repo.diff(commit.parents.first, commit).patch.to_s.split("\n").each_with_index.map { |line, index| "%4d %s" % [index + 1, line] }.join("\n")
      commit_message = commit.message
      commit_diff = repo.diff(commit.parents.first, commit).patch.to_s
      commit_details = commit_message + "\n" + commit_diff
      commit_details = commit_details.split("\n")
      max_digits = commit_details.size.to_s.length
      commit_details = commit_details.each_with_index.map { |line, index| "%#{max_digits}d %s" % [index + 1, line] }.join("\n")
      #commit_details = commit_details.each_with_index.map { |line, index| "%4d %s" % [index + 1, line] }.join("\n")

      prompt = build_merge_prompt(conflicted_content, commit_details, path)

      #puts "\n==================================\n#{prompt}\n==================================\n"

      puts conflicted_content

      response = ""
      catch(:close) do
        llmc.completions(
          parameters: {
            prompt: prompt,
            max_tokens: 128000,
            stream: proc do |chunk, _bytesize|
              response += chunk["choices"].first["text"]
              print chunk["choices"].first["text"] # stream to console

              block_marker_count = response.split("\n").select { |line| line.start_with?("```") }.size
              
              if block_marker_count == 2
                response += "\n"
                puts
                throw :close 
              end
            end
          }
        )
      end

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
          next
        end

        error = false
        solution_end.downto(solution_start) do |line_number|
          if !solution_numbered_hash.has_key?(line_number)
            puts "Missing line #{line_number}"
            error = true
          end
        end
        next if error

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

        File.write(full_path, new_content.join("\n"))
        if merge_blocks == 1
          repo.index.add(path)
        end
        ported = true
      else
        puts "Failed to get valid solution for #{path}"
        exit
        next
      end
    end

    ported_str = ""
    if ported
      ported_str = "\nPorted-by: rllm"
      puts "Successfully resolved all conflicts in #{sha}"
    end

    # Create commit if all conflicts are resolved
    if repo.index.conflicts.empty?
      options = {
        tree: repo.index.write_tree(repo),
        author: commit.author,
        committer: commit.committer,
        message: commit.message + ported_str,
        parents: [repo.head.target],
        update_ref: 'HEAD'
      }
      res = Rugged::Commit.create(repo, options)
      repo.index.write_tree(repo)
      puts "Successfully committed #{sha} as #{res}"
    else
      puts "Failed to resolve all conflicts in #{sha}"
      exit
    end
  rescue => e
    puts "Error processing #{sha}: #{e}"
    puts e.backtrace
    exit
  end
end