#!/usr/bin/env ruby
#
require 'yaml'
require 'optparse'

def symbolize_yaml_keys hash
    if hash.is_a? Hash
        hash.inject({}) { |memo, (key, value)|
            memo[if key.is_a? String then key.to_sym else key end] = symbolize_yaml_keys value
            memo
        }
    elsif hash.is_a? Array
        hash.map { |item| symbolize_yaml_keys item }
    else
        hash
    end
end

class TmuxProfileLoader

    def initialize verbosity
        @verbosity = verbosity
    end

    def die *args
        puts *args
        exit 1
    end
    def info *args
        puts *args if @verbosity >= 1
    end
    def debug *args
        puts *args if @verbosity >= 2
    end
    def trace *args
        puts *args if @verbosity >= 3
    end


    def session_exists? name
        system "tmux has-session -t #{name} 2> /dev/null"
    end


    # Runs command in current shell
    def run cmd, args=[]
        cmd = "#{cmd} #{args.join ' '}".strip
        info cmd
        `#{cmd}`
    end


    # Sends keys to tmux pane
    def send_to_pane pane, keys
        keys = [ keys ] unless keys.is_a? Array
        keys = keys.map { |key|
            "'#{key}'".gsub /'''/, '"\'"'
        }
        run "tmux send-keys", ["-t #{pane}", keys.join(' ')]
    end


    # Runs a command within shell inside tmux
    def run_in_pane pane, cmds
        cmds = [ cmds ] unless cmds.is_a? Array
        cmds.each do |cmd|
            keys = cmd.split("")
            keys << "Enter"
            send_to_pane pane, keys
        end
    end

    def profile_dirs
        [
          './profiles',
          '~/.config/tmux/profiles',
        ].map { |filename|
          File.expand_path(filename, File.dirname(__FILE__))
        }
    end

    def find_profile(profile_name)
        profile_dir = profile_dirs.find { |dir_name|
          File.exist? "#{dir_name}/#{profile_name}.yaml"
        }
        "#{profile_dir}/#{profile_name}.yaml" unless profile_dir.nil?
    end

    def background
        # get current terminal height/width
        w = `tput cols`.strip
        h = `tput lines`.strip
        "-d -x #{w} -y #{h}"
    end

    # Loads profile by name
    def load_profile profile_name
        run "tmux start-server"

        default_window = {}

        profile = find_profile(profile_name)

        die "Profile not found: '#{profile_name}'" if profile.nil?

        begin
            profile = YAML.load_file profile
        rescue
            die "Profile '#{profile_name}' is not valid YAML."
        end

        profile = symbolize_yaml_keys profile
        debug "Profile: #{YAML.dump profile}"

        # initialize all sessions
        profile[:sessions].each do |session|
            if session.nil?
                created_info = run "tmux new-session #{background} -P -F '\#{session_id}'"
                debug "Created empty session #{created_info.strip}"
            else
                if !session[:name].nil? and session_exists? session[:name]
                    info "Session '#{session[:name]}' already exists. Skipping."
                    next
                end

                debug "Creating session #{YAML.dump session}"

                window = unless session[:windows].nil? then session[:windows].first else default_window end

                # create session
                window[:dir] ||= session[:dir]
                args = []
                args << "-s #{session[:name]}" unless session[:name].nil?
                args << "-n #{window[:name]}" unless window[:name].nil?
                args << "-c #{window[:dir]}" unless window[:dir].nil?
                args << background
                args << '-P -F "#{session_id} #{window_id} #{pane_id}"'
                created_info = run "tmux new-session", args
                debug "Created '#{created_info}'"

                session[:id], window[:id],  = created_info.strip.split.map { |id| "'#{id}'" }
                debug "Created session #{session[:id]} with window #{window[:id]}"

                # create more windows
                unless session[:windows].nil?
                    session[:windows][1..-1].each do |window|
                        window[:dir] ||= session[:dir]
                        args = []
                        args << "-t #{session[:id]}"
                        args << "-n #{window[:name]}" unless window[:name].nil?
                        args << "-c #{window[:dir]}" unless window[:dir].nil?
                        args << "-d"
                        args << '-P -F "#{window_id}"'
                        created_info = run "tmux new-window", args

                        window[:id] = "'#{created_info.strip}'"
                        debug "Created window #{window[:id]}"
                    end
                end

                # initialize windows
                unless session[:windows].nil?
                    session[:windows].each do |window|
                        n = "#{session[:id]}:#{window[:id]}"
                        debug "Initializing window #{n}"

                        run_in_pane n, window[:cmd] unless window[:cmd].nil?
                        send_to_pane n, window[:send] unless window[:send].nil?

                        panes = window[:panes] || []
                        panes.each do |pane|
                            pane[:dir] ||= window[:dir]
                            args = []
                            args << "-t #{n}"
                            args << "-c #{pane[:dir]}" unless pane[:dir].nil?
                            args << "-#{ pane[:split][0] || "h" } "
                            args << "-l #{pane[:size]} " unless pane[:size].nil?
                            run "tmux split-window", args
                            cmds = pane[:cmd]
                            run_in_pane n, cmds unless cmds.nil?
                            send = pane[:send]
                            send_to_pane n, send unless send.nil?
                        end
                    end
                end
            end

        end

        # attach first specified session
        profile[:sessions].each do |session|
            if session[:attach]
                run "tmux attach", ["-t #{session[:id]}"]
                break
            end
        end

    end

end

def check_deps
    raise "Please install tmux" unless `which tmux` != ""
end

options = { :verbosity => 1 }
parser = OptionParser.new do |opts|

  opts.banner = "Usage: #{ File.basename __FILE__ } [-l] [-v[v]] [-q] PROFILE"

  opts.on("-l", "--list", "List available profiles (ignores -q)") do |l|
    options[:list] = l
  end
  opts.on("-v", "--verbose", "Print verbose output") do |l|
    options[:verbosity] += 1
  end
  opts.on("-q", "--quiet", "Suppress output") do |l|
    options[:verbosity] = 0
  end

end


if __FILE__ == $0

    check_deps()
    parser.parse! ARGV

    if options[:list]
        profile_dirs.each { |dir|
          puts "#{dir}:"
          puts Dir.new(dir)
                  .select { |f| f =~ /\.yaml$/ }
                  .map { |f| f.sub ".yaml", "" }
                  .join "\n"
          puts
        }
    elsif ARGV.length > 0
        TmuxProfileLoader.new(options[:verbosity]).load_profile ARGV.first
    else
        puts parser
    end
end

