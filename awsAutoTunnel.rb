#! /usr/bin/ruby
# Will create a reverse tunnel after starting an EC2 instance exposing access to the system from where this script was triggered.
# Takes in a JSON configuration file on the specification of the EC2 instance. which include keys -- 
# access -- An array of the of the access ID and key to your AWS account.
# region -- The region in which the EC2 instance resides.
# instance_id -- Contains the ID of the instance to start.
# sshkey -- Path of the unencrypted private key to the sshd server.
# sshuser -- The ssh user to use to create the reverse tunnel.
# exposePorts -- What port will the server be listening to for the created reverse tunnel.
# sshPort -- SSH port of the server on the EC2 instance.
# privateIP -- The private IP of the server to which the reverse tunneled connection will listen to. This's probably the IP of the interface via which you access the Internet.
# localIP -- The IP to which the connection will map on the client. This's probably localhost, or the IP to which the sshd on your system listens to.
# localPort -- The port to which the connection will map on the client (your system).
# writeIntervel -- The interval between which this script will write to the created SSH session to the ec2 instance to test the connection.
# ServerAliveCountMax -- Sets the number of keepalive packets which may be sent by ssh without receiving any mes‐sages back from the server. If this threshold is reached, the ssh connection will be retried.
# ServerAliveInterval -- Intervals between keepalive packets for ssh.
# ConnectTimeout -- The timeout (in seconds) used when connecting to the SSH server (the started instance)
# Config file location will be the first argument to the script.
# 
# 
# Will terminate the instance under a SIGTERM and quit.
# Will use the ssh command to create the reverse tunnel without a tty. Will retry till infinity if ssh dies.
# Will send echo command to stdin to see if things are working. ssh client will die automatically if it's not.
# 
# Algo -- 
# 10) Construct arguments to instances.
# 20) Start instance. Script exists if it's unsuccessful
# 30) Enter create ssh tunnel loop.
# 40) Intercept a SIGTERM
# 50) Terminate ssh tunnel
# 60) Stop instance.
require 'oj'
require 'aws-sdk'
Oj.default_options = { :symbol_keys => true, :bigdecimal_as_decimal => true, :mode => :compat, 'load' => :compat }
config = ARGF.read
config = Oj.load(config)
# Creating has arguments to create_instances and setting credentials. Cant pass to create_instances directly since many keys are optional.
instanceArgs = Hash.new
creds = nil
# algo 10
config.each {
	|key, value|
	case key
	when :access
		creds = Aws::Credentials.new(value[0], value[1])
	when :instance_id
		instanceArgs[:instance_ids] = [value]
	end
}
if creds == nil
	puts 'No credentials specified'
	exit
end
client = Aws::EC2::Client.new({:region => config[:region] , :credentials => creds})
resource = Aws::EC2::Resource.new({:client => client})

# start instance
rsshInstance = resource.instances(instanceArgs).first
# Algo 20. Not sure what to do when it does not start properly.
rsshInstance.start
instancePIP = nil
# Get public IP.
puts 'attempting to determine public IP'
while instancePIP == nil
	sleep 1
	instancePIP = rsshInstance.public_ip_address
	rsshInstance.reload
end
sshcmd = ['ssh', '-T', '-o', "ServerAliveCountMax=#{config[:ServerAliveCountMax]}", '-o', "ServerAliveInterval=#{config[:ServerAliveInterval]}", '-o', "ConnectTimeout=#{config[:ConnectTimeout]}", '-i', config[:sshkey], '-p', config[:sshPort].to_s, '-R', "#{config[:privateIP]}:#{config[:exposePorts]}:#{config[:localIP]}:#{config[:localPort]}", "#{config[:sshuser]}@#{instancePIP}"]
puts 'executing ssh....'
begin
	sshcmdIP = IO.popen(sshcmd, 'w')
# 	algo 30.
	while 5 != 6
		if sshcmdIP.closed?
			sshcmdIP = IO.popen(sshcmd, 'w')
			puts 'ssh terminated, retrying'
		end
		sleep config[:writeIntervel]
		sshcmdIP.puts('echo test > /dev/null')
	end
# 	algo 40
rescue SignalException => exceptionError
	if (exceptionError.signo == 2) || (exceptionError.signo == 15)
# 		algo 60.
		puts 'Shutting down instance.'
		rsshInstance.stop
		rsshInstance.wait_until({:max_attempts => 9999, :delay => 5}) {
			|instance|
			puts 'waiting for shutdown...'
			instance.state.code >= 32
		}
	else
		exit
	end
rescue Errno::EPIPE
	puts 'ssh terminated, retrying'
	retry
end
