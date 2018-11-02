class MessageBus::Diagnostics
  def self.full_process_path
    begin
      system = `uname`.strip
      if system == "Darwin"
        `ps -o "comm=" -p #{Process.pid}`
      elsif system == "FreeBSD"
        `ps -o command -p #{Process.pid}`.split("\n", 2)[1].strip()
      else
        info = `ps -eo "%p|$|%a" | grep '^\\s*#{Process.pid}'`
        info.strip.split('|$|')[1]
      end
    rescue
      # skip it ... not linux or something weird
    end
  end

  def self.hostname
    begin
      `hostname`.strip
    rescue
      # skip it
    end
  end

  def self.enable(bus = MessageBus)
    full_path = full_process_path
    start_time = Time.now.to_f
    hostname = self.hostname

    # it may make sense to add a channel per machine/host to streamline
    #  process to process comms
    bus.subscribe('/_diagnostics/hup') do |msg|
      if Process.pid == msg.data["pid"] && hostname == msg.data["hostname"]
        $shutdown = true
        sleep 4
        Process.kill("HUP", $$)
      end
    end

    bus.subscribe('/_diagnostics/discover') do |msg|
      bus.on_connect.call msg.site_id if bus.on_connect
      bus.publish '/_diagnostics/process-discovery', {
        pid: Process.pid,
        process_name: $0,
        full_path: full_path,
        uptime: (Time.now.to_f - start_time).to_i,
        hostname: hostname
      }, user_ids: [msg.data["user_id"]]
      bus.on_disconnect.call msg.site_id if bus.on_disconnect
    end
  end
end
