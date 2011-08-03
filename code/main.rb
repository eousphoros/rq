

require 'sinatra/base'
require 'erb'
load 'code/queuemgrclient.rb'
load 'code/queueclient.rb'
load 'code/hashdir.rb'
load 'code/portaproc.rb'
load 'code/overrides.rb'
load 'code/htmlutils.rb'

module RQ
  class Main < Sinatra::Base
    def self.views
      './code/views'
    end

    helpers do
      def url
        "http://#{request.host}:#{request.port}/"
      end

      def get_queueclient(name)
        # SPECIAL CASE - we allow relay and cleaner
        # No RQ should be connecting to another box's relay
        # However, users need the web ui to interact, so we think
        # this is safe and good for debugging/visiblity
        if File.exists?("./config/rq_router_rules.rb")
          if not ['relay', 'cleaner'].include?(name)
            name = 'rq_router'
          end
        end
        RQ::QueueClient.new(name)
      end
    end

    get '/' do
      erb :main
    end

    get '/new_queue' do
      erb :new_queue
    end

    post '/new_queue' do
      # TODO: validation

      # This creates and starts a queue
      params['queue']['url'] = url
      result = RQ::QueueMgrClient.create_queue(params['queue'])
      "We got <pre> #{params.inspect} </pre> from form, and #{result} from QueueMgr"
    end

    get '/q.txt' do
      content_type 'text/plain', :charset => 'utf-8'
      erb :queue_list, :layout => false, :locals => {:queues => RQ::QueueMgrClient.queues}
    end

    get '/proc.txt' do
      content_type 'text/plain', :charset => 'utf-8'
      ps = RQ::PortaProc.new
      ok, procs = ps.get_list
      if not ok
        throw :halt, [503, "503 - Could not get process list"]
      end
      erb :proc_list, :layout => false, :locals => {:queues => RQ::QueueMgrClient.queues, :procs => procs}, :trim => '-'
    end

    get '/q/:name' do
      if params[:name].index(".txt")
        content_type 'text/plain', :charset => 'utf-8'
        return erb :queue_txt, :layout => false, :locals => { :qc => RQ::QueueClient.new(params[:name].split(".txt").first) }
      elsif params[:name].index(".json")
        if '.json' == params[:name][-5..-1]
          return erb :queue_json, :layout => false, :locals => { :qc => RQ::QueueClient.new(params[:name].split(".json").first) }
        end
      end

      if not RQ::QueueMgrClient.running?
        throw :halt, [503, "503 - QueueMgr not running"]
      end

      # check for queue
      # TODO: sanitize names (no dots or slashes)
      qc = RQ::QueueClient.new(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      erb :queue
    end

    get '/q/:name/done.json' do
      if not RQ::QueueMgrClient.running?
        throw :halt, [503, "503 - QueueMgr not running"]
      end

      qc = RQ::QueueClient.new(params[:name])
      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      limit = 10
      if params['limit']
        limit = params['limit'].to_i
      end
      result = qc.messages({'state' => 'done', 'limit' => limit})
      "#{result.to_json}"
    end

    get '/q/:name/new_message' do
      # check for queue
      # TODO: sanitize names (no dots or slashes)
      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      overrides = RQ::Overrides.new(params['name'])
      erb :new_message, :layout => true, :locals => {:o => overrides }
    end

    post '/q/:name/new_message' do
      api_call = params.fetch('x_format', 'json')
      if api_call == 'html'
        prms = params['mesg'].clone
      else
        prms = JSON.parse(params['mesg'])
      end

      # Normalize some values
      if prms.has_key? 'post_run_webhook' and prms['post_run_webhook'].is_a? String
        # clean webhook input of any spaces
        # Ruby split..... so good!
        prms['post_run_webhook'] = prms['post_run_webhook'].split ' '
      end
      if prms.has_key? 'count'
        prms['count'] = prms['count'].to_i
      end
      if prms.has_key? 'max_count'
        prms['max_count'] = prms['max_count'].to_i
      end

      the_method = prms.fetch("_method", 'commit')

      # request.host and request.port are setup by the config file
      hostnames = [ "http://#{request.host}:#{request.port}/" ]
      if File.exists? "./config/aliases.json"
        begin
          js_data = JSON.parse(File.read("./config/aliases.json"))
          hostnames.concat(js_data['hostnames'] || [])
        rescue
          p $!
          p "BAD aliases.json - could not parse"
          throw :halt, [404, "404 - Couldn't parse existing aliases.json file."]
        end
      end

      if hostnames.any? {|h| prms['dest'].index(h) == 0}
        q_name = params[:name]
      else
        if (prms['relay_ok'] == 'yes') && (the_method != 'single_que')
          q_name = 'relay' # Relay is the special Q
        else
          throw :halt, [404, "404 - Not this Queue. Relaying not allowed"]
        end
      end

      qc = get_queueclient(q_name)

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      if the_method == 'prep'
        result = qc.prep_message(prms)
      elsif the_method == 'single_que'
        result = qc.single_que(prms)
      elsif the_method == 'commit'
        result = qc.create_message(prms)
      else
        throw :halt, [404, "404 - Queue not found"]
      end

      if result == [ "fail", "oper_status: DOWN"]
        throw :halt, [503, "503 - Service Unavailable - Operationally Down"]
      end

      if api_call == 'json'
        "#{result.to_json}"
      else
        erb :new_message_post, :layout => true, :locals => {:result => result, :q_name => q_name }
      end
    end

    get '/q/:name/restart' do
      res = RQ::QueueMgrClient.restart_queue(params[:name])

      if not res
        throw :halt, [500, "500 - Couldn't restart queue. Internal error."]
      end
      if res[0] != 'ok'
        throw :halt, [500, "500 - Couldn't restart queue. #{res.inspect}."]
      end

      <<-HERE
        <script type="text/javascript">
        <!--
        function delayer(){
            history.back();
        }
        setTimeout('delayer()', 1000);
        //-->
        </script>
        Queue restarted... (returning in 1 sec)
      HERE
    end

    get '/q/:name/config.json' do
      path = "./queue/#{params['name']}/config.json"

      if not File.exists? path
        throw :halt, [404, "404 - Queue config for '#{params['name']}' not found"]
      end

      send_file(path)
    end

    get '/q/:name/:msg_id' do
      # check for queue
      # TODO: sanitize names (no dots or slashes)

      fmt = :html
      msg_id = params['msg_id']

      extension = msg_id[-5..-1]
      if extension == '.json'
        fmt = :json
        msg_id = msg_id[0..-6]
      end

      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      ok, msg = qc.get_message({ 'msg_id' => msg_id })

      if ok != 'ok'
        throw :halt, [404, "404 - Message ID not found"]
      end

      if fmt == :html
        erb :message, { :locals => { 'msg_id' => msg_id, 'msg' => msg } }
      else
        #content_type 'application/json'
        msg.to_json
      end
    end

    get '/q/:name/:msg_id/clone' do
      qc = get_queueclient(params[:name])
      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end
      res = qc.clone_message({ 'msg_id' => params[:msg_id] })

      if not res
        throw :halt, [500, "500 - Couldn't restart queue. Internal error."]
      end
      if res[0] != 'ok'
        throw :halt, [500, "500 - Couldn't restart queue. #{res.inspect}."]
      end

      <<-HERE
        <script type="text/javascript">
        <!--
        function delayer(){
          location.href = "/q/#{params[:name]}";
        }
        setTimeout('delayer()', 1000);
        //-->
        </script>
        Message cloned... (going to queue in 1 sec)
      HERE
    end

    post '/q/:name/:msg_id/attach/new' do
      # check for queue
      # TODO: sanitize names (no dots or slashes)
      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      # Sample of what params look like
      # {"name"=>"test", "filedata"=>{:type=>"image/jpeg", :head=>"Content-Disposition: form-data; name=\"data\"; filename=\"studio3.jpg\"\r\nContent-Type: image/jpeg\r\n", :tempfile=>#<File:/var/folders/st/st7hSqrMFB0Sfm3p4OeypE+++TM/-Tmp-/RackMultipart20091218-76387-t47zdi-0>, :name=>"filedata", :filename=>"studio3.jpg"}, "msg_id"=>"20091215.1829.21.853", "x_format"=>"json"}
      #
      #p params
      #p params['filedata']
      #p params['filedata'][:tempfile].path
      #p params['filedata'][:tempfile].class
      #p params['filedata'][:tempfile].methods.sort

      if not params['filedata']
        throw :halt, [404, "404 - Missing required param filedata"]
      end

      if params['filedata'].class != Hash
        throw :halt, [404, "404 - Wrong input type for filedata param"]
      end

      if not params['filedata'][:tempfile]
        throw :halt, [404, "404 - Missing pathname to upload temp file in filedata param"]
      end

      if not params['filedata'][:filename]
        throw :halt, [404, "404 - Missing filename of uploaded file in filedata param"]
      end


      api_call = params.fetch('x_format', 'html')

      msg = { 'msg_id' => params['msg_id'],
        'pathname' => params['filedata'][:tempfile].path,
        'name' => params['filedata'][:filename]
      }

      result = qc.attach_message( msg )

      # Success - clean up temp file
      if result[0] == "ok"
        File.unlink(params['filedata'][:tempfile].path) rescue nil
      end

      if api_call == 'json'
        result.to_json
      else
        "Commit #{params[:name]}/#{params[:msg_id]} got #{result}"
      end
    end

    get '/q/:name/:msg_id/log/:log_name' do

      msg_id = params['msg_id']

      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      ok, msg = qc.get_message({ 'msg_id' => msg_id })

      if ok != 'ok'
        throw :halt, [404, "404 - Message ID not found"]
      end

      if ['done', 'relayed'].include? msg['state']
        path = RQ::HashDir.path_for("./queue/#{params['name']}/#{msg['state']}", params['msg_id'])
        path += "/job/#{params['log_name']}"
      else
        path = "./queue/#{params['name']}/#{msg['state']}/#{params['msg_id']}/job/#{params['log_name']}"
      end

      # send_file does this check, but we provide a much more contextually relevant error
      # TODO: finer grained checking (que, msg_id exists, etc.)
      if not File.exists? path
        throw :halt, [404, "404 - Message ID log '#{params['log_name']}' not found"]
      end

      data = File.read(path)

      # Assumption: log output does not contain HTML. This is a good safe assumption
      # First escape any HTML unsafe chars
      data2 = RQ::HtmlUtils.escape_html(data)
      # OK, now we can linkify (aka add html), to make urls actual links
      data3 = RQ::HtmlUtils.linkify_text(data2)
      # Finally, do the necessary work to colorize via html text that used ANSI escape codes
      data4 = RQ::HtmlUtils.ansi_to_html(data3)

      tmpurl = "http://#{request.host}:#{request.port}#{request.path_info}"

      ["<html><head><title>#{tmpurl}</title></head><body><pre>", data4, '</pre></body></html>'].join("\n")
    end

    get '/q/:name/:msg_id/attach/:attach_name' do

      msg_id = params['msg_id']

      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      ok, msg = qc.get_message({ 'msg_id' => msg_id })

      if ok != 'ok'
        throw :halt, [404, "404 - Message ID not found"]
      end

      # TODO: use path from get_message instead of below
      if ['done', 'relayed'].include? msg['state']
        path = RQ::HashDir.path_for("./queue/#{params['name']}/#{msg['state']}", params['msg_id'])
        path += "/attach/#{params['attach_name']}"
      else
        path = "./queue/#{params['name']}/#{msg['state']}/#{params['msg_id']}/attach/#{params['attach_name']}"
      end

      # send_file does this check, but we provide a much more contextually relevant error
      # TODO: finer grained checking (que, msg_id exists, etc.)
      if not File.exists? path
        throw :halt, [404, "404 - Message ID attachment '#{params['attach_name']}' not found"]
      end

      send_file(path)
    end

    post '/q/:name/:msg_id' do
      # check for queue
      # TODO: sanitize names (no dots or slashes)
      qc = get_queueclient(params[:name])

      if not qc.exists?
        throw :halt, [404, "404 - Queue not found"]
      end

      api_call = params.fetch('x_format', 'html')

      if params[:_method] == 'delete'
        result = qc.delete_message( {'msg_id' => params[:msg_id]} )
        "Delete #{params[:name]}/#{params[:msg_id]} got #{result}"
      elsif params[:_method] == 'commit'
        result = qc.commit_message( {'msg_id' => params[:msg_id]} )
        if api_call == 'json'
          result.to_json
        else
          "Commit #{params[:name]}/#{params[:msg_id]} got #{result}"
        end
      else
        "Post #{params[:name]}/#{params[:msg_id]}"
      end
    end

  end
end
