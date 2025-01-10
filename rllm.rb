#!/usr/bin/env ruby

require 'rubygems'
require 'rugged'
require 'optparse'
require 'uri'
require 'net/http'
require 'json'
require 'fileutils'
require 'pathname'

require 'openai'
require 'net/ssh'

require_relative './lib/merge_iteration'
require_relative './lib/fixup_iteration'
require_relative './lib/ask_and_gather_context'
require_relative './lib/run_ssh_commands'
require_relative './lib/utils'

# Configuration
# cmake .. -DGGML_CUDA=ON -DGGML_RPC=ON -DGGML_CUDA_F16=true -DGGML_CUDA_PEER_MAX_BATCH_SIZE=256 -DGGML_CUDA_FA_ALL_QUANTS=true
# CUDA_VISIBLE_DEVICES="1" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/granite-3.1-8b-instruct.Q8_0.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8080 -fa -ctk q4_0 -ctv q4_0
# CUDA_VISIBLE_DEVICES="0,1,2" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/Llama-3.1-Nemotron-70B-Instruct-HF-IQ4_XS.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8081 -fa -ctk q4_0 -ctv q4_0 -ts 20,5,20 -mg 1 -ub 512 -b 4096

LLAMA_API_ENDPOINT_GOOD_SLOW = 'http://localhost:8081'
LLAMA_API_ENDPOINT_MEH_FAST = 'http://localhost:8080'
LOG_FILE = 'rllm.log'

options = {}

repo_dir = '/home/snajpa/linux'
src_commit = '0bc21e701a6f' # random linux commit
cherrypick_commit_range = 'd3e69f8ab5df..c09b3eaeafd9' # syslog-ns
#src_commit = '0bc21e701a6f' # 6.13-rc5+
#cherrypick_commit_range = '319addc2ad90..68eb45c3ef9e'
#src_commit = '8155b4ef3466' # next-20240104
#cherrypick_commit_range = 'd3e69f8ab5df..c0dcbf44ec68' # from 6.12.7
dst_branch_name = 'vpsadminos-devel'
dst_remote_name = 'origin'

OpenAI.configure do |config|
  config.access_token = ""
  config.log_errors = true
  config.uri_base = LLAMA_API_ENDPOINT_GOOD_SLOW
  config.request_timeout = 900
end

OptionParser.new do |opts|
  opts.banner = "Usage: rllm.rb [options]"
end.parse!

repo = Rugged::Repository.new(repo_dir)

llmc = OpenAI::Client.new
llmc_fast = OpenAI::Client.new(uri_base: LLAMA_API_ENDPOINT_MEH_FAST)

range = cherrypick_commit_range.split('..')
walker = Rugged::Walker.new(repo)
walker.push(repo.lookup(range[1]).oid)
walker.hide(repo.lookup(range[0]).oid)
commit_list = walker.map(&:oid).reverse

def force_push(repo_dir, dst_remote_name, dst_branch_name)
  `cd #{repo_dir} && git push -f #{dst_remote_name} #{dst_branch_name}`
  $?
end

def ssh_build_iteration(ssh_host, ssh_user, ssh_options, quiet, dst_remote_name, dst_branch_name, dir, cores, &block)
  commands = [
    { cmd: "cd #{dir}; git fetch", can_fail: false },
    { cmd: "cd #{dir}; git checkout -f master", can_fail: false },
    { cmd: "cd #{dir}; git branch -D #{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git reset --hard #{dst_remote_name}/#{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git checkout --progress -b #{dst_branch_name} #{dst_remote_name}/#{dst_branch_name}", can_fail: false },
    { cmd: "cd #{dir}; make -j #{cores}", can_fail: true }
  ]
  run_ssh_commands("172.16.106.12", "root", ssh_options, quiet, commands, &block)
end

puts "Starting merge process"
puts "Source commit: #{src_commit}"
puts "Cherrypick commit range: #{cherrypick_commit_range}"
puts "Destination branch: #{dst_branch_name}"
puts "Destination remote: #{dst_remote_name}"
puts "Repository: #{repo_dir}"

def extract_error_context(b)
  error_context_lines = []
  was_error = false
  b[:results].last[:output_lines].each do |line|
    if line =~ /error:/i
      was_error = true
    end
    if was_error
      error_context_lines << line
    end
  end
  error_context_lines.join("\n")
end

prev_results = {}
if File.exist?('merge_results.bin') && prev_results.empty?
  f = File.open('merge_results.bin', 'r')
  prev_results = Marshal.load(f.read)
  f.close
  #File.delete('merge_results.bin')
  puts "Loaded previous merge results"
end

quiet = false
ssh_options = {
  # verbose: :debug,
  use_agent: true,
  config: true,
  verify_host_key: :never
}
error_context = ""
fixup_patch_str = ""
compiled_ok = false
max_iterations = 10
iter = 0
begin
  while !compiled_ok && iter < max_iterations
    iter += 1
    prev_results = merge_iteration(llmc, 0.8, repo,
                                   src_commit, commit_list, dst_branch_name,
                                   llmc_fast, 768, 2048, 24*iter, error_context, prev_results)
    puts "Saving merge results"
    f = File.open('merge_results.bin', 'w')
    f.write(Marshal.dump(prev_results))
    f.close

    pushed = false
    3.times do
      f = force_push(repo_dir, dst_remote_name, dst_branch_name)
      pushed = f.exitstatus == 0
      break if pushed
    end
    exit 1 unless pushed

    max_fixup_iterations = 10
    fixup_ok = false
    fixup_iter = 0
    while !compiled_ok && fixup_iter < max_fixup_iterations
      fixup_iter += 1
      b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                              dst_remote_name, dst_branch_name, "~/linux-rllm", 64)
      #do |ch, command, line|
      #  if line =~ /error:/i
      #    puts "Error detected, closing connection"
      #    command[:exit_status] = 1
      #    ch.close
      #    raise
      #  end
      #end
      error_context = extract_error_context(b)

      compiled_ok = b[:results].last[:exit_status] == 0
      puts "Compiled OK: #{compiled_ok}"

      if !compiled_ok && error_context.length > 0
        puts "\nRunning fixup iteration #{fixup_iter}/#{max_fixup_iterations}\n\n"
        fixup_ok = fixup_iteration(llmc, 0.3, repo, error_context, fixup_patch_str,
                                  llmc_fast, 768, 2048, 48)
        if fixup_ok
          puts "Fixup OK, retrying build"
        else
          puts "Fixup failed, continuing with next merge iteration"
        end
      end

      # We should now commit the fixup changes and feed them back to the merge iteration
      
      if fixup_ok
        # Commit all changes using Rugged
        tree_before = repo.head.target.tree
        index = repo.index
        index.add_all
        index.write
        commit_oid = Rugged::Commit.create(repo, {
          tree: index.write_tree(repo),
          author: { email: "snajpa@snajpa.net", name: "Pavel Snajdr (via rllm)", time: Time.now },
          committer: { email: "snajpa@snajpa.net", name: "Pavel Snajdr (via rllm)", time: Time.now },
          message: "Fixup iteration #{fixup_iter}",
          parents: [repo.head.target]
        })
        repo.references.update("HEAD", commit_oid)
        puts "Committed fixup changes"

        diff = tree_before.diff(repo.lookup(commit_oid).tree)

        # Output like git show, commit message first, then diff
        puts "commit #{commit_oid}"
        puts "Author: #{repo.lookup(commit_oid).author[:name]} <#{repo.lookup(commit_oid).author[:email]}>"
        puts "Date:   #{repo.lookup(commit_oid).author[:time]}"
        puts
        repo.lookup(commit_oid).message.each_line do |line|
          puts "    #{line}"
        end
        puts
        puts diff.patch

        fixup_patch_str = ""
        fixup_patch_str += "commit #{commit_oid}\n"
        fixup_patch_str += "Author: #{repo.lookup(commit_oid).author[:name]} <#{repo.lookup(commit_oid).author[:email]}>\n"
        fixup_patch_str += "Date:   #{repo.lookup(commit_oid).author[:time]}\n"
        fixup_patch_str += "\n"
        repo.lookup(commit_oid).message.each_line do |line|
          fixup_patch_str += "    #{line}"
        end
        fixup_patch_str += "\n"
        fixup_patch_str += diff.patch
      end
    end
  end
rescue Interrupt => e
  puts "Merge iteration interrupted: #{e.message}"
  puts "Saving merge results"
  f = File.open('merge_results.bin', 'w')
  f.write(Marshal.dump(prev_results))
  f.close
end