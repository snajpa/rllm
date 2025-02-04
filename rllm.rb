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
require_relative './lib/ed'
require_relative './lib/ui'

# Configuration
# cmake .. -DGGML_CUDA=ON -DGGML_RPC=ON -DGGML_CUDA_F16=true -DGGML_CUDA_PEER_MAX_BATCH_SIZE=64 -DGGML_CUDA_FA_ALL_QUANTS=true
# CUDA_VISIBLE_DEVICES="1" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/granite-3.1-8b-instruct.Q8_0.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8080 -fa -ctk q4_0 -ctv q4_0 --slot-save-path ~/tmp/llama-cache/
# CUDA_VISIBLE_DEVICES="0,1,2" ~/tmp/llama.cpp/build-rpc-cuda/bin/llama-server --no-mmap -m ~/models/Llama-3.1-Nemotron-70B-Instruct-HF-IQ4_XS.gguf -ngl 99 -c 131072 -t 8 --host 0.0.0.0 --port 8081 -fa -ctk q4_0 -ctv q4_0 -ts 20,4,20 -mg 1 -ub 512 -b 4096 --slot-save-path ~/tmp/llama-cache/
# Nhrs=6; find ~/tmp/llama-cache/ -type f -amin +$(($Nhrs * 60)) -exec rm {} \;

$compile_last = true
$caching_enabled = true

LLAMA_API_ENDPOINT_GOOD_SLOW = 'http://localhost:8081'
LLAMA_API_ENDPOINT_MEH_FAST = 'http://localhost:8080'
LOG_FILE = 'rllm.log'

repo_dir = '/home/snajpa/linux'

src_sha = 'c45323b7560e' # random linux commit
#cherrypick_commit_range = '319addc2ad90..cf9971c0322e' # upto: tmpfs: use 1/2 of memcg limit if present v3
cherrypick_commit_range = 'd3e69f8ab5df..c09b3eaeafd9' # syslog-ns
#src_sha = '0bc21e701a6f' # 6.13-rc5+
#cherrypick_commit_range = '319addc2ad90..68eb45c3ef9e' # full stack from 6.12.7
#src_sha = '8155b4ef3466' # next-20240104
#cherrypick_commit_range = 'd3e69f8ab5df..c0dcbf44ec68'

dst_branch_name = 'vpsadminos-devel'
dst_remote_name = 'desktop'

OpenAI.configure do |config|
  config.access_token = ""
  config.log_errors = true
  config.uri_base = LLAMA_API_ENDPOINT_GOOD_SLOW
  config.request_timeout = 900
end

OptionParser.new do |opts|
  opts.banner = "Usage: rllm.rb [options]"
end.parse!

class AppUi
  attr_accessor :top_panes
  def initialize(startit, init_tree, init_status)
    @started = false
    return unless startit
    @log = ""
    @infer_log = ""
    @infer_log_logprobs = ""
    @infer_log_logprobs_tokens = ""
    @meta_tree_data = init_tree.dup
    
    @tty_tree_data = NcursesUI::meta_to_tty_tree(@meta_tree_data)
    @node_lookup = NcursesUI::build_node_lookup(@meta_tree_data)

    @top_panes = Widgets::TopSubPanes.new(2)
    @tree_pane = Widgets::TreePane.new(@tty_tree_data)
    @content_pane = Widgets::ContentPane.new
    @status_bar = Widgets::StatusBar.new

    @ui = NcursesUI.new(
      top_panes:    @top_panes,
      tree_pane:    @tree_pane,
      content_pane: @content_pane,
      status_bar:   @status_bar,
      node_lookup:  @node_lookup
    )

    start
    update_status(init_status)
    @ui.post_event(:disable_tail_mode_bottom)
    @ui.post_event(cmd: :update_bottom_content, lines: (1..90).map{|i| "Line #{i}"})
  end

  def update_tree(&block)
    new_meta_tree_data = block_given? ? block.call(@meta_tree_data) : @meta_tree_data
    @meta_tree_data = new_meta_tree_data
    if @meta_tree_data.nil?
      $stderr.puts "Meta tree data is nil"
      exit
    end
    @ui.post_event(cmd: :update_tree, meta_tree_data: @meta_tree_data)
  end

  def infer_log(msg)
    unless @started
      print msg
      return
    end
    @infer_log += msg
    #@infer_log += "\n" unless @infer_log.end_with?("\n")
    @ui.post_event(cmd: :update_top_pane, index: 0, :ui_content => @infer_log.split("\n"))
  end

  def infer_log_logprobs(msg)
    unless @started
      #puts msg
      return
    end
    @infer_log_logprobs += msg
    @infer_log_logprobs += "\n" unless @infer_log_logprobs.end_with?("\n")
    @ui.post_event(cmd: :update_top_pane, index: 1, :ui_content => @infer_log_logprobs.split("\n"))
  end
  def infer_log_logprobs_tokens(msg)
    unless @started
      #puts msg
      return
    end
    @infer_log_logprobs_tokens += msg
    @infer_log_logprobs_tokens += "\n" unless @infer_log_logprobs_tokens.end_with?("\n")
    @ui.post_event(cmd: :update_top_pane, index: 1, :ui_content => @infer_log_logprobs.split("\n"))
  end
  def log(msg)
    unless @started
      puts msg
      return
    end
    @log += msg
    @log += "\n" unless @log.end_with?("\n")
    @meta_tree_data["Root"][:ui_content] = @log.split("\n")
    update_tree
    update_status @log.split("\n").last
  end

  def update_status(message)
    @ui.post_event(cmd: :update_status, message: message)
  end
  def start
    @ui.start
    @started = true
  end
  def stop
    @started = false
    @ui.post_event(:stop)
  end
  def join
    @ui.join
  end
end

$ui = AppUi.new(ARGV.empty?,
  { "Root" => { :ui_content => ["Initializing..."], :children => {} } },
  "Initializing..."
)

def logme(*msga)
  $ui.log(msga.join("\n"))
end

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

def ssh_build_iteration(tree, ssh_host, ssh_user, ssh_options, quiet, dst_remote_name, dst_branch_name, dir, cores, &block)
  commands = [
    { cmd: "cd #{dir}; git fetch #{dst_remote_name}", can_fail: false },
    { cmd: "cd #{dir}; git checkout -f master", can_fail: false },
    { cmd: "cd #{dir}; git branch -D #{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git reset --hard #{dst_remote_name}/#{dst_branch_name}", can_fail: true },
    { cmd: "cd #{dir}; git checkout --progress -b #{dst_branch_name} #{dst_remote_name}/#{dst_branch_name}", can_fail: false },
    { cmd: "cd #{dir}; cp ~/okconfig ~/linux-rllm/.config", can_fail: false },
    { cmd: "cd #{dir}; make -j #{cores}", can_fail: true }
  ]
  run_ssh_commands("172.16.106.12", "root", ssh_options, quiet, commands, &block)
end

logme "Starting merge process"
logme "Source commit: #{src_sha}"
logme "Cherrypick commit range: #{cherrypick_commit_range}"
logme "Destination branch: #{dst_branch_name}"
logme "Destination remote: #{dst_remote_name}"
logme "Repository: #{repo_dir}"

def extract_error_context(b)
  error_context_lines = {}
  error_lines = []
  b[:results].last[:output_lines].each_with_index do |line, index|
    if line =~ /error:/i
      error_lines << index
    end
  end
  error_lines.each do |line|
    start = [0, line - 5].max
    stop = [b[:results].last[:output_lines].size - 1, line + 5].min
    b[:results].last[:output_lines].each_with_index do |line, index|
      if index >= start && index <= stop
        error_context_lines[index] = line
      end
    end
  end
  error_context_lines.sort.join("\n") + "\n"
end

prev_results = {}
if File.exist?('merge_results.bin') && prev_results.empty?
  f = File.open('merge_results.bin', 'r')
  prev_results = Marshal.load(f.read)
  f.close
  #File.delete('merge_results.bin')
  logme "Loaded previous merge results"
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
      commit_str = "#{sha[0..7]} - #{commit.message.split("\n").first}"
      iters_str = "\n#{iter}/#{max_iterations} iters, commit: #{n_commit}/#{n_commits} #{commit_str}: "
      logme "#{iters_str}merging commit"

      # Setup initial branch state
      repo.reset(reset_target, :hard)
      repo.checkout(reset_target)
      begin
        repo.branches.delete(dst_branch_name)
      rescue Rugged::ReferenceError
      end
      repo.branches.create(dst_branch_name, reset_target)
      repo.checkout("refs/heads/#{dst_branch_name}")

      # Try merge iteration
      result = merge_iteration(llmc, 0.4, repo, reset_target, dst_branch_name, src_sha, sha, llmc_fast,
                               8192, 8192, 1*iter, results[sha], error_context)
      results[sha] = result if result[:resolved]
      #next unless result[:resolved]

      #reset_target = result[:reset_target]

      # Only do this if we're doing the last commit
      if $compile_last && (n_commit != n_commits)
        logme "Skipping build for non-last commit"
        reset_target = result[:commited_as]
        build_ok = true
        next
      else
        if !result[:llm_ported] && (!$compile_last || n_commit != n_commits)
          # Validation not needed when LLM didn't touch the code
          logme "Skipping build for non-ported commit"
          build_ok = true
          reset_target = result[:commited_as]
          next
        end
      end
      
      # Try push
      #pushed = false
      #3.times do
      #  f = force_push(repo.workdir, dst_remote_name, dst_branch_name)
      #  pushed = f.exitstatus == 0
      #  break if pushed
      #end
      #next unless pushed
      
      15.times do |fixup_iter|
        logme "#{iters_str}Build and fixup iteration #{fixup_iter}\n\n"
        # Try build
        b = ssh_build_iteration("172.16.106.12", "root", ssh_options, quiet,
                              dst_remote_name, dst_branch_name, "~/linux-rllm", 64)
        build_ok = b[:results].last[:exit_status] == 0
        
        if !build_ok
          logme "#{iters_str}Build failed, trying to fixup the error, iteration #{fixup_iter}"
          error_context = extract_error_context(b)
          fixup_result = fixup_iteration(llmc, 0.3, repo, sha, error_context, "", 
                                         llmc_fast, 768, 2048, 25*iter)             
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
            logme "#{iters_str}Fixup commit #{commit_oid} created\n\n"
            #reset_target = commit_oid
          else
            logme fixup_result[:message]
          end
        else
          reset_target = result[:commited_as]
          logme "#{iters_str}Build successful!"
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
  $stderr.puts "Process interrupted: #{e.message}"
end

$ui.stop
$ui.join
puts "Main thread: UI has shut down. Exiting."