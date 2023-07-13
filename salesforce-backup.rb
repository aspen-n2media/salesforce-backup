#!/usr/bin/ruby

require 'net/http'
require 'net/https'
require 'rexml/document'
require 'date'
require 'net/smtp'
require 'fileutils'

include REXML

class Result
  def initialize(xmldoc)
    @xmldoc = xmldoc
  end

  def server_url
    @server_url ||= XPath.first(@xmldoc, '//result/serverUrl/text()')
  end

  def session_id
    @session_id ||= XPath.first(@xmldoc, '//result/sessionId/text()')
  end

  def org_id
    @org_id ||= XPath.first(@xmldoc, '//result/userInfo/organizationId/text()')
  end
end

class SfError < Exception
  attr_accessor :resp

  def initialize(resp)
    @resp = resp
  end

  def inspect
    puts resp.body
  end
  alias_method :to_s, :inspect
end

### Helpers ###

def http(host = ENV['SALESFORCE_SITE'], port = 443)
  h = Net::HTTP.new(host, port)
  h.use_ssl = true
  h
end

def headers(login)
  {
    'Cookie'         => "oid=#{login.org_id.value}; sid=#{login.session_id.value}",
    'X-SFDC-Session' => login.session_id.value
  }
end

#string file name, "salesforce-uid-date"
def file_name(url=nil)
  datestamp = Date.today.strftime('%Y-%m-%d')
  uid_string = url ? "-#{/.*fileName=(.*)\.ZIP.*/.match(url)[1]}" : ''
  filenumber = uid_string[(22 - uid_string.size)]
  return "salesforce-#{uid_string}-#{datestamp}.ZIP"
end

#string current date, each backup is named after the day it occured
def current_date()
  return Date.today.strftime('%Y-%m-%d')
end

### Salesforce interactions ###

def login
  puts "Logging in..."
  path = '/services/Soap/u/58.0'

  pwd_token_encoded = "#{ENV['SALESFORCE_USER_PASSWORD']}#{ENV['SALESFORCE_SECURITY_TOKEN']}"
  pwd_token_encoded = pwd_token_encoded.gsub(/&(?!amp;)/,'&amp;')
  pwd_token_encoded = pwd_token_encoded.gsub(/</,'&lt;')
  pwd_token_encoded = pwd_token_encoded.gsub(/>/,'&gt;')
  pwd_token_encoded = pwd_token_encoded.gsub(/"/,'&quot;')
  pwd_token_encoded = pwd_token_encoded.gsub(/'/,'&apos;')

  puts "<n1:password>#{pwd_token_encoded}</n1:password>"
  puts "<n1:username>#{ENV['SALESFORCE_USERNAME']}</n1:username>"

  initial_data = <<-EOF
<?xml version="1.0" encoding="utf-8" ?>
<env:Envelope xmlns:xsd="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
  <env:Body>
    <n1:login xmlns:n1="urn:partner.soap.sforce.com">
      <n1:username>#{ENV['SALESFORCE_USERNAME']}</n1:username>
      <n1:password>#{pwd_token_encoded}</n1:password>
    </n1:login>
  </env:Body>
</env:Envelope>
  EOF

  initial_headers = {
    'Content-Type' => 'text/xml; charset=UTF-8',
    'SOAPAction' => 'login'
  }

  resp = http('login.salesforce.com').post(path, initial_data, initial_headers)

  if resp.code == '200'
    puts "code 200"
    xmldoc = Document.new(resp.body)
    return Result.new(xmldoc)
  else
    puts "error"
    raise SfError.new(resp)
  end
end

def download_index(login)
  puts "Downloading index..."
  path = '/servlet/servlet.OrgExport'
  data = http.post(path, nil, headers(login))
  data.body.strip
end

def get_download_size(login, url)
  puts "Getting download size..."
  data = http.head(url, headers(login))
  data['Content-Length'].to_i
end

#deletes directories that are ENV['RCLONE_RETENTION'] older than current date from ENV['DATA_DIRECTORY']
def delete_outdated_directories()
  directory_names = Dir.glob("*/").select { |f| File.directory?(f) }
  directory_names.each do |x|
    if DateTime.parse(x) - ENV['RCLONE_RETENTION'] < Date.today()
      #delete x
    end
  end
end

def download_file(login, url, expected_size, backup_directory)
  printing_interval = 10
  interval_type = :percentage
  last_printed_value = nil
  size = 0
  fn = file_name(url)
  puts "Downloading #{fn}..."
  f = open("#{backup_directory}/#{fn}", "wb")
  begin
    http.request_get(url, headers(login)) do |resp|
      resp.read_body do |segment|
        f.write(segment)
        size = size + segment.size
        last_printed_value = print_progress(size, expected_size, printing_interval, last_printed_value, interval_type)
      end
      puts "\nFinished downloading #{fn}!"
    end
  ensure
    f.close()
  end
  raise "Size didn't match. Expected: #{expected_size} Actual: #{size}" unless size == expected_size
end

def print_progress(size, expected_size, interval, previous_printed_interval, interval_type=:seconds)
  percent_file_complete = ((size.to_f/expected_size.to_f)*(100.to_f)).to_i
  case interval_type
    when :percentage
    previous_printed_interval ||= 0
    current_value = percent_file_complete
    when :seconds
    previous_printed_interval ||= Time.now.to_i
    current_value = Time.now.to_i
  end
  next_interval = previous_printed_interval + interval
  if current_value >= next_interval
    timestamp = Time.now.strftime('%Y-%m-%d-%H-%M-%S')
    puts "#{timestamp}: #{percent_file_complete}% complete (#{size} of #{expected_size})"
    return next_interval
  end
  return previous_printed_interval
end

### Email ###

# def email_success(file_name, size)
#   subject = "Salesforce backup successfully downloaded"
#   data = "Salesforce backup saved into #{file_name}, size #{size}"
#   email(subject, data)
# end

# def email_failure(url, error_msg)
#   subject = "Salesforce backup download failed"
#   data = "Failed to download #{url}. #{error_msg}"
#   email(subject, data)
# end

# def email(subject, data)
#   message = <<END
# From: Admin <#{ENV['EMAIL_ADDRESS_FROM']}>
# To: Admin <#{ENV['EMAIL_ADDRESS_TO']}>
# Subject: #{subject}

# #{data}
# END
#   Net::SMTP.start(ENV['SMTP_HOST']) do |smtp|
#     smtp.send_message message, ENV['EMAIL_ADDRESS_FROM'], ENV['EMAIL_ADDRESS_TO']
#   end
# end

def run_backup
    result = login
    timestamp_start = Time.now.strftime('%Y-%m-%d-%H-%M-%S')
    urls = download_index(result).split("\n")
    backup_directory = "#{ENV['DATA_DIRECTORY']}/#{current_date()}"
    puts "#{timestamp_start}: Started!"
    puts "  All URLs:"
    puts urls
    puts ''
  
    unless File.directory?("#{backup_directory}/")
      FileUtils.mkdir_p("#{backup_directory}/")
      puts backup_directory
      puts 'directory made'
    end
    
    FileUtils.mkdir_p("/Salesforce Backup/TestScript/testbackupscript/")

    file_path = '/Salesforce Backup/TestScript/testbackupscript.txt'

    File.open(file_path, 'w') do |file|
      file.write("This is a Salesforce backup file.")
    end
    urls.each do |url|
      fn = file_name(url)
      file_path = "#{backup_directory}/#{fn}"
      retry_count = 0
      begin
        puts "Working on: #{url}"
        expected_size = get_download_size(result, url)
        puts "Expected size: #{expected_size}"
        fs = File.size?(file_path)
  
        if fs && fs == expected_size
          puts "File #{fn} exists and is the right size. Skipping."
        else
          download_file(result, url, expected_size, backup_directory)
          ## email_success(file_path, expected_size)
        end
      rescue Exception => e
        if retry_count < 5
          retry_count += 1
          puts "Error: #{e}"
          puts "Retrying (retry_count of 5)..."
          retry
        else
          #email_failure(url, e.to_s)
        end
      end
    end
  end
  
  while true
    puts "started"
    run_backup
    #delete_files
    timestamp_done = Time.now.strftime('%Y-%m-%d-%H-%M-%S')
    puts "#{timestamp_done}: Done!"
    sleep(3600) #3600 seconds in an hour
    #TODO sleep indefinitely until an email is sent with info that a new salesforce backup occured
  end
  
