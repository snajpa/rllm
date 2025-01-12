def get_file_context(repo, path, linenumbers, context_lines = 8)
  file_path = File.join(repo.workdir, path)
  return "" unless File.exist?(file_path)
  return "" if File.directory?(file_path)
  lines = File.read(file_path).split("\n") || []
  return "" if lines.empty?
  context = {}
  linenumbers.each do |linenumber|
    start = [0, linenumber - context_lines].max
    stop = [lines.size - 1, linenumber + context_lines].min
    lines.each_with_index do |line, index|
      if index >= start && index <= stop
        context[start + index] = line
      end
    end
  end
  max_digits = context.keys.max.to_s.length
  context.sort.map { |k, v| "%#{max_digits}d %s" % [k+1, v] }.join("\n")
end

def save_slot(client, save_name)
  return 501 unless $caching_enabled

  begin
    server_url = client.uri_base
    uri = URI.parse(server_url + "/slots/0?action=save")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 30
    http.read_timeout = 300
    
    request = Net::HTTP::Post.new(uri.request_uri, {'Content-Type' => 'application/json'})
    request.body = { filename: save_name }.to_json
    
    response = http.request(request)
    
    if response.is_a?(Net::HTTPSuccess)
      #puts "Slot saved successfully with name: #{save_name}"
      response.code.to_i
    else
      #puts "Failed to save slot: #{response.code} - #{response.body}"
      response.code.to_i
    end
  rescue => e
    #puts "Failed to save slot: #{e.message}"
    #puts e.backtrace
    500
  end
end

def restore_slot(client, save_name)
  return 501 unless $caching_enabled

  begin
    server_url = client.uri_base
    uri = URI.parse(server_url + "/slots/0?action=restore")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 30
    http.read_timeout = 60
    
    request = Net::HTTP::Post.new(uri.request_uri, {'Content-Type' => 'application/json'})
    request.body = { filename: save_name }.to_json
    
    response = http.request(request)
    
    if response.is_a?(Net::HTTPSuccess)
      #puts "Slot restored successfully with name: #{save_name}"
      response.code.to_i
    else
      #puts "Failed to restore slot: #{response.code} - #{response.body}"
      response.code.to_i
    end
  rescue => e
    #puts "Failed to restore slot: #{e.message}"
    #puts e.backtrace
    500
  end
end

def warmup_kv_cache_common_prompt(client, common_prompt)
  return 501 unless $caching_enabled

  save_name = Digest::SHA256.hexdigest(common_prompt)

  #puts "Warming up KV cache by loading cache save..."
  ret = restore_slot(client, save_name)
  if ret == 501
    #puts "KV cache unsupported. Skipping..."
    return
  elsif ret == 400
    print "(KV #{ret}..."
    client.completions(
      parameters: {
        temperature: 0.0,
        max_tokens: 1,
        prompt: common_prompt
      }
    )
    ret = save_slot(client, save_name)
    if ret == 200
      print " saved) "
    else
      print " failed) "
    end
  else
    #puts "KV cache restored. Ret code: #{ret}"
  end
end