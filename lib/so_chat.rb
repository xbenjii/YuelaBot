class SoChat
    include Discordrb::Webhooks

    attr_reader :room_id, :channel_id

    class << self
        def cookies=(cookies)
            @cookies = cookies
        end

        def cookies
            @cookies
        end

        def all
            ObjectSpace.each_object(self).to_a
        end

        def stop!(room_id, channel_id)
            all.select { |sc| sc.room_id == room_id && sc.channel_id == channel_id }.each(&:stop!)
        end
    end

    def initialize(channel_id, room_id, user, pass, base_url = "https://chat.stackoverflow.com")
        @room_id = room_id
        @channel_id = channel_id
        @user = user
        @pass = pass
        @base_url = base_url
        @listeners = {}
        @history = []
    end

    def stop!
        @thread.terminate if @thread
    end

    def listen!
        stop!
        @thread = Thread.new do
            Thread.current.abort_on_exception = true
            p 'authenticating'
            auth!
            on :message do |e|
                next unless e['content']
                if is_onebox?(e['content'])
                    handle_onebox(e)
                else
                    handle_message(e)
                end
            end
            on(:edit) { |e| handle_edit(e) }
            on(:delete) { |e| handle_delete(e) }
            run!
        end
    end

    private

    def handle_tweet(html)
        tweet_info = html.css('div.ob-tweet-info > a')
        BOT.send_message(@channel_id, tweet_info[1].attr('href'))
    end

    def handle_image(html)
        img_url = html.at_css('img').attr('src')
        BOT.send_message(@channel_id, "http:#{img_url}")
    end

    def handle_onebox(e)
        onebox = Nokogiri::HTML(e['content'])
        type = onebox.at_css('div.onebox').attributes['class'].value.split(' ')[1]
        case type
        when 'ob-tweet'
            handle_tweet(onebox)
        when 'ob-image'
            handle_image(onebox)
        end
    end

    def is_onebox?(message)
        !!Nokogiri::HTML(message).at_css('div.onebox')
    end

    def process_tag!(message, tag, repl1, repl2 = nil)
        repl2 = repl1 unless repl2
        message.gsub!(/<#{tag}.*?>/, repl1)
        message.gsub!(/<\/#{tag}>/, repl2)
    end

    def process_content(message)
        message = CGI.unescapeHTML(message)
        html = Nokogiri::HTML(message)
        if html.at_css('div')
            message = html.at_css('div').inner_html.gsub(' <br> ', "\n")
        end
        process_tag!(message, 'code', '`')
        process_tag!(message, 'pre', "```javascript\n", "```\n")
        process_tag!(message, 'i', '*')
        process_tag!(message, 'b', '**')
        process_tag!(message, 'strike', '~~')
        process_tag!(message, 'a', '')
        message.gsub! "&gt;", ">"
        message
    end

    def handle_message(e)
        message = process_content(e['content'])
        last = @history.last
        unless last && last[:so_message]['user_id'] == e['user_id']
            BOT.send_message(@channel_id, "**#{e['user_name']}**:")
        end
        sent_message = BOT.send_message(@channel_id, message)
        @history << {
            so_message: e,
            discord_message: sent_message
        }
        @history.shift if @history.length >= 100
    end

    def handle_edit(e)
        edited_message = @history.find { |h| h[:so_message]['message_id'] == e['message_id'] }
        return unless edited_message
        message = process_content(e['content'])
        edited_message[:discord_message] = edited_message[:discord_message].edit(message)
    end

    def handle_delete(e)
        deleted_message = @history.find { |h| h[:so_message]['message_id'] == e['message_id']}
        return unless deleted_message
        discord_message = deleted_message[:discord_message]
        content = discord_message.content
        deleted_message[:discord_message] = discord_message.edit("#{content} [deleted]")
    end

    def auth!
        begin
            cookies = login
            @ws_url = get_ws_url(cookies)
        rescue RestClient::NotFound
            p "SO Chat authorization failed"
            sleep 30
            auth!
        end
    end

    def on(type, &callback)
        @listeners[type] = callback
    end

    def run!
        EM.run do
            inner_run
        end
    end

    private 

    def inner_run
        ws = Faye::WebSocket::Client.new("#{@ws_url}?l=99999999999", nil, { 
            headers: {
                "origin" => @base_url
            }   
        })
        
        ws.on :message do |msg|
            events = JSON.parse(msg.data)["r#{@room_id}"]['e']
            next unless events
            events.each do |e|
                case e['event_type']
                when 1
                    @listeners[:message]&.call(e)
                when 2
                    @listeners[:edit]&.call(e)
                when 10
                    @listeners[:delete]&.call(e)
                end
            end
        end

        ws.on(:open) do |e| 
            p 'ws opened' 
        end
        
        ws.on(:error) do |e|
            p 'ws error'
            p e.data, e.code, e.reason
        end

        ws.on(:close) do |e| 
            p 'ws closed', e
        end
    end

    def get_fkey(path, cookies = nil)
        resp = RestClient.get(path, cookies: cookies) 
        Nokogiri::HTML(resp.body).at_css('input[name="fkey"]').attr('value')
    end

    def get_ws_url(cookies)
        fkey = get_fkey(@base_url, cookies)
        data = "roomid=#{@room_id}&fkey=#{fkey}"
        resp = RestClient.post("#{@base_url}/ws-auth", {
            roomid: @room_id,
            fkey: fkey
        }, {
            Origin: @base_url,
            Referer: "#{@base_url}/rooms/#{@room_id}",
            content_type: 'application/x-www-form-urlencoded',
            user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36",
            "X-Requested-With" => "XMLHttpRequest",
            cookies: cookies
        }) do |resp, req, res|
            case resp.code
            when 301, 302, 307
                resp.follow_redirection
            else
                resp.return!
            end
        end
        JSON.parse(resp.body)['url']
    end

    def login
        return SoChat.cookies if SoChat.cookies
        url = 'https://stackoverflow.com/users/login'
        fkey = get_fkey(url)
        resp = RestClient.post(url, {
            fkey: fkey,
            email: @user,
            password: @pass
        }, {
            "Content-Type": "application/x-www-form-urlencoded"
        }) do |resp, req, res|
           case resp.code
            when 301, 302, 307
                resp.follow_redirection
            else
                resp.return!
            end 
        end       
        SoChat.cookies = resp.cookie_jar
    end
end