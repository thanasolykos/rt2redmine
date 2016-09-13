# This file is part of the Minnesota Population Center's rt2redmine project.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/mnpopcenter/rt2redmine

require 'rest-client'
require 'JSON'
require 'active_resource'
require 'mysql'
require 'yaml'

$config = (YAML.load_file('config/config.yml'))['json2redmine']

# Capture global configuration for the ActiveResource objects

class RestAPI < ActiveResource::Base 
    
  # overriding ActiveResource::Base's default handling of headers, because we need to set a different
  # value for the X-Redmine-Switch-User header on each request, and after much testing, this is the
  # way to do that
  cattr_accessor :static_headers
   self.static_headers = headers
   
   cattr_accessor :redmine_user

   def self.headers
     new_headers = static_headers.clone
     if self.redmine_user
       new_headers["X-Redmine-Switch-User"] = RestAPI.redmine_user # voila, evaluated at request-time
     end
     new_headers
   end
  # end header behavior modification
   
  # set our ActiveResource config
  self.site = $config['url']
  # a user's API key to create the Issues.  Will be set at the author so should
  # probably use a service account.
  self.user = $config['key']
  # random string required for password when using API key as user
  self.password = 'abcd'
  
  # this hack fixed a problem where I would get "Subject can't be blank" when trying
  # to save the Issue. Thanks Google!
  self.include_root_in_json = true   
  
  # ACTIVATE for DEBUGGING OUTPUT (not too useful, but somewhat)
  # RestAPI.logger = Logger.new(STDERR)
end

# subclass from RestAPI for Issues.  So far, this is the only one we need.
# (thought we needed User but thus far not yet)
class Issue < RestAPI; 
  self.element_name = "issue" 
end

# we will need a DB connection - see why later
conn = Mysql.new($config['dbhost'], $config['dbuser'], $config['dbpass'], $config['database'])

directories = Dir.entries($config['tickets_directory']).sort_by {|s| s.to_i } 
directories.each() do |ticketdir|
  next if ticketdir == '.' or ticketdir == '..'
  # do work on real items
  # skip if below start number
  next if ticketdir.to_i < $config['start']
  
  jsonfile = $config['tickets_directory'] + ticketdir + '/' + ticketdir + '.json'
  file = File.read(jsonfile)
  ticket = JSON.parse(file)
  
  # get RT ID
  rt_id = /ticket\/(\d+)/.match(ticket['id'])[1]
  
  # Creating an issue
  issue = Issue.new(
    :subject => '[' + ticket['Requestors'] + " - RT \##{rt_id}" + '] ' + ticket['Subject'],
    :project_id => $config['project_id'],
    :description => (ticket['Description'] || ticket['Transactions'][0]['Content']),
    # tracker 6 is request
    :tracker_id => 6
  )

  RestAPI.redmine_user = false
  # general pattern to follow when doing a .save - first try as the RT username (hoping
  # there is an equivalent Redmine login), then
  # fall back to the Redmine administrative account
  begin
    # attempt to impersonate user who created ticket
    matcharray = (/(.*?)@umn.edu/i).match(ticket['Creator'])
    username = matcharray[1] if matcharray
    if username
      puts "Trying to create issue as username #{username}"
      RestAPI.redmine_user = username
    end
    if issue.save
      puts "Created #{issue.id} from RT #{ticket['id']}"
    else
      puts issue.errors.full_messages
    end
  rescue ActiveResource::ClientError => msg
    # revert to using admin as user 
    RestAPI.redmine_user = false
    if issue.save
      puts "Could not create as user (#{msg.response.code}). Created #{issue.id} from RT #{ticket['id']} as redmine admin."
    else
      puts issue.errors.full_messages
    end    
  end 
  
  # set status
  stat_id = 0
  # determine status
  if ticket['Status'] == 'resolved'
    stat_id = $config['closed_status_id']
  else 
    stat_id = $config['open_status_id']
  end
  
  # connect to the DB and manually reset the created_on date to the creation time of original ticket
  # tried many ways to do this in a Rails-y way but nothing seems to work for Rails 4 as it did for Rails 3
  time = DateTime.parse(ticket['Created'])
  conn.query( "UPDATE issues set created_on = '#{time}', status_id = #{stat_id} where id = #{issue.id}" ) do |result|
    if (result.result_status != 1) 
      puts "ERROR: FAILED TO UPDATE created_on and status_id FOR ISSUE."
    end
  end
  
  # track most recent transaction for this issue
  last_trans_date = time

  # back to API usage
  RestAPI.redmine_user = false
  # add the ticket history
  ticket['Transactions'].drop(1).each do |trans|
    issue.notes = '[' + trans['Creator'] + '] ' + trans['Content']
    
    begin
      # attempt to impersonate user who created transaction
      matcharray = (/$config['username_regex']/i).match(trans['Creator'])
      username = matcharray[1] if matcharray
      if username   
        puts "Trying to add transaction as username #{username}"
        RestAPI.redmine_user = username
      end
      if res = issue.save
        puts "Added #{trans['Type']} transaction to #{issue.id}"
      else
        puts issue.errors.full_messages
      end
    rescue ActiveResource::ClientError => msg
      # revert to using admin as user 
      RestAPI.redmine_user = false
      if res = issue.save
        puts "Could not add transaction as user (#{msg.response.code}). Added #{trans['Type']} transaction to #{issue.id} as redmine admin."
      else
        puts issue.errors.full_messages
      end    
    end
    
    # for each notes entry, alter its created_on date
    # because ActiveResource sucks, I'm reverting to SQL here
    # first, I need the journal ID that was assigned, this would be the latest journaled item (don't run this
    # while others are using the system)
    # I realize this is a terrible hack.  I'm too frustrated with ActiveResource to care.
    trans_id = -1
    conn.query("SELECT max(id) FROM journals") do |result|
        trans_id = result.fetch_row[0]       
    end
    
    # connect to the DB and manually reset the updated_on date to the time of transaction
    # tried many ways to do this in a Rails-y way but nothing seems to work for Rails 4 as it did for Rails 3
    time = DateTime.parse(trans['Created'])
    conn.query( "UPDATE journals set created_on = '#{time}' where id = #{trans_id}" ) do |result|
      if (result.result_status != 1)
        puts "ERROR: FAILED TO UPDATE updated_on FOR TRANSACTION."
      end
    end 
    last_trans_date = time
  end
  
  # add the attachments, if any
  # don't know how to do this via ActiveResource, going to do this with rest client
  # attachments are all attached using the redmine admin API key.  I don't think this loses any useful info.
    
  if Dir.exists?($config['tickets_directory'] + ticketdir + '/attachments/')
    directories = Dir.entries($config['tickets_directory'] + ticketdir + '/attachments/').sort_by {|s| s.to_i } 
    directories.each do |file|
      next if file == '.' or file == '..'
      File.open($config['tickets_directory'] + ticketdir + '/attachments/' + file, 'rb') do |f|
        puts "Processing attachment #{file}"
        file_name = File.basename(f)
        begin
          # First we upload the image to get an attachment token
          response = RestClient::Request.execute(:url => $config['upload_url'] + "?key=#{$config['key']}", :method => :post, :payload => f, :headers => {:multipart => true, :content_type => 'application/octet-stream'}, :verify_ssl => false)      
        rescue RestClient::UnprocessableEntity => ue
          p "The following exception typically means that the file size of '#{file_name}' exceeds the limit configured in Redmine."
          raise ue
        end
        token = JSON.parse(response)['upload']['token']
        id = issue.id
        issue_url = $config['issue_url_base'] + "#{id}.json?key=#{$config['key']}"
        response = RestClient::Request.execute(:url => issue_url, :method => :put, :verify_ssl => false, :payload => {
          :attachments => {
            :attachment1 => {
              :token => token,
              :filename => file_name,
            }
          } } )
          
          # update the file attachment transaction date
          trans_id = -1
          conn.query("SELECT max(id) FROM journals") do |result|
              trans_id = result.fetch_row[0]       
          end
          # connect to the DB and manually reset the updated_on date to the time of transaction
          # tried many ways to do this in a Rails-y way but nothing seems to work for Rails 4 as it did for Rails 3
          # just use ticket creation time for attachments - close enough
          time = DateTime.parse(ticket['Created'])
          conn.query( "UPDATE journals set created_on = '#{time}' where id = #{trans_id}" ) do |result|
            if (result.result_status != 1)
              puts "ERROR: FAILED TO UPDATE created_on FOR ATTACHMENT."
            end
          end 
          
          # update the file uploaded date on attachments, same technique as above
          trans_id = -1
          conn.query("SELECT max(id) FROM attachments") do |result|
              trans_id = result.fetch_row[0]       
          end
          # connect to the DB and manually reset the updated_on date to the time of transaction
          # tried many ways to do this in a Rails-y way but nothing seems to work for Rails 4 as it did for Rails 3
          # just use ticket creation time for attachments - close enough
          time = DateTime.parse(ticket['Created'])
          conn.query( "UPDATE attachments set created_on = '#{time}' where id = #{trans_id}" ) do |result|
            if (result.result_status != 1)
              puts "ERROR: FAILED TO UPDATE created_on FOR ATTACHMENT."
            end
          end 
          
      end
    end
  end
  
  # update ticket with date of last transaction
  conn.query( "UPDATE issues set updated_on = '#{last_trans_date}' where id = #{issue.id}" ) do |result|
    if (result.result_status != 1)
      puts "ERROR: FAILED TO UPDATE updated_on for issue."
    end
  end 
  
  puts "----------------------------------------------"   
end
