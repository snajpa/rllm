#!/usr/bin/env ruby

require 'rubygems'
require 'rugged'
require 'optparse'
require 'uri'
require 'net/http'
require 'json'
require 'fileutils'
require 'pathname'
require 'digest'

require 'openai'
require 'net/ssh'

require_relative './lib/merge_iteration'
require_relative './lib/fixup_iteration'
require_relative './lib/ask_and_gather_context'
require_relative './lib/run_ssh_commands'
require_relative './lib/utils'

# Configuration
# cmake .. -DGGML_CUDA=ON -DGGML_RPC=ON -DGGML_CUDA_F16=true -DGGML_CUDA_PEER_MAX_BATCH_SIZE=256 -DGGML_CUDA_FA_ALL_QUANTS=true
# CUDA_VISIBLE_DEVICES="1" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/granite-3.1-8b-instruct.Q8_0.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8080 -fa -ctk q4_0 -ctv q4_0 --slot-save-path ~/tmp/llama-cache/
# CUDA_VISIBLE_DEVICES="0,1,2" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/Llama-3.1-Nemotron-70B-Instruct-HF-IQ4_XS.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8081 -fa -ctk q4_0 -ctv q4_0 -ts 20,5,20 -mg 1 -ub 512 -b 4096 --slot-save-path ~/tmp/llama-cache/

$caching_enabled = true

LLAMA_API_ENDPOINT_GOOD_SLOW = 'http://localhost:8081'
LLAMA_API_ENDPOINT_MEH_FAST = 'http://localhost:8080'
LOG_FILE = 'rllm.log'

options = {}

repo_dir = '/home/snajpa/linux'

src_sha = ""
cherrypick_commit_range = ""
if false
src_sha = '0bc21e701a6f' # random linux commit
cherrypick_commit_range = 'd3e69f8ab5df..c09b3eaeafd9' # syslog-ns
end
if true
  src_sha = '0bc21e701a6f' # 6.13-rc5+
  cherrypick_commit_range = '319addc2ad90..68eb45c3ef9e'
end
if false
  src_sha = '8155b4ef3466' # next-20240104
  cherrypick_commit_range = 'd3e69f8ab5df..c0dcbf44ec68' # from 6.12.7
end

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
    { cmd: "cd #{dir}; cp ~/okconfig ~/linux-rllm/.config", can_fail: false },
    { cmd: "cd #{dir}; make -j #{cores}", can_fail: true }
  ]
  run_ssh_commands("172.16.106.12", "root", ssh_options, quiet, commands, &block)
end

puts "Starting merge process"
puts "Source commit: #{src_sha}"
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

def process_commit_list(quiet, llmc, llmc_fast, ssh_options, dst_remote_name, repo, src_sha, commit_list, dst_branch_name)
  results = {}
  src_commit = repo.lookup(src_sha)
  
  # Setup initial branch state
  repo.reset(src_commit.oid, :hard)
  repo.checkout(src_commit.oid)
  begin
    repo.branches.delete(dst_branch_name)
  rescue Rugged::ReferenceError
  end
  repo.branches.create(dst_branch_name, src_commit.oid)
  repo.checkout("refs/heads/#{dst_branch_name}")
  reset_target = src_commit.oid
  
  n_commits = commit_list.size
  commit_list.each_with_index do |sha, index|
    commit = repo.lookup(sha)
    n_commit = commit_list.index(sha) + 1
    
    merge_ok = false
    build_ok = false
    error_context = ""
    max_iterations = 10
    iter = 0
    
    while !build_ok && iter < max_iterations
      iter += 1
      
      puts "\n#{iter}/#{max_iterations} iters: Processing commit #{n_commit}/#{n_commits}: #{sha[0..7]} - #{commit.message.split("\n").first}"

      # Try merge iteration
      result = merge_iteration(llmc, 0.8, repo, reset_target, dst_branch_name, src_sha, sha, llmc_fast,
                               768, 2048, 2*iter, results[sha], error_context)
      results[sha] = result if result[:resolved]
      #reset_target = result[:reset_target]

      # Only do this if we're doing the last commit
      unless n_commit == n_commits
        puts "Skipping build for non-last commit"
        build_ok = true
        next
      end
      
      # Try push
      pushed = false
      3.times do
        f = force_push(repo.workdir, dst_remote_name, dst_branch_name)
        pushed = f.exitstatus == 0
        break if pushed
      end
      next unless pushed
      
      5.times do |fixup_iter|
        # Try build
        b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                              dst_remote_name, dst_branch_name, "~/linux-rllm", 64)
        build_ok = b[:results].last[:exit_status] == 0
        
        if !build_ok
          error_context = extract_error_context(b)
          fixup_result = fixup_iteration(llmc, 0.3, repo, sha, error_context, "", 
                                         llmc_fast, 768, 2048, 3)
                                      
          if fixup_result[:success]
            # Commit fixup changes
            repo.index.write
            commit_oid = Rugged::Commit.create(repo, {
              tree: repo.index.write_tree(repo),
              author: { email: "snajpa@snajpa.net", name: "Pavel Snajdr (via rllm)", time: Time.now },
              committer: { email: "snajpa@snajpa.net", name: "Pavel Snajdr (via rllm)", time: Time.now },
              message: "Fixup iteration #{fixup_iter}",
              parents: [repo.head.target],
              update_ref: "HEAD"
            })
            repo.reset(commit_oid, :hard)
            #reset_target = commit_oid
          end
        else
          break
        end
      end
    end
  end
  
  results
end

# Main execution
begin
  results = process_commit_list(quiet, llmc, llmc_fast, ssh_options, dst_remote_name, repo, src_sha, commit_list, dst_branch_name)
rescue Interrupt => e
  puts "Process interrupted: #{e.message}"
end