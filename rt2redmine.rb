require 'rubygems'
require 'roart'

class Ticket < Roart::Ticket
  connection :server => 'http://192.168.56.101/', :user => 'root', :pass => 'password'
end

my_tickets = Ticket.find(:all, :queue => 'mpc-admin')
my_tickets.each do |ticket|
  puts ticket.subject
end
