use Error qw(:try);
use RT::Client::REST;
use MIME::Parser;
use Data::Dumper;

# if/when we get non-Shib access, we can take this approach
# # test server
# #my $rt = RT::Client::REST->new(server => 'http://192.168.56.101');
# # real server
# my $rt = RT::Client::REST->new(server => 'https://rt.cla.umn.edu');
#
# try {
#   # test server login
#   # $rt->login(username => 'root', password => 'password');
#   # real server login
#   $rt->login(username => 'fran@umn.edu', password => '***REMOVED***');
# } catch Exception::Class::Base with {
#   die "Can't login: ", shift->message;
# };
#
# try {
#   #$t = $rt->show(type => 'ticket', id => 1);
#   my @ids = $rt->search(type => "ticket", query => "Queue = 'mpc-admin'");
#   print Dumper(\@ids);
# } catch RT::Client::REST::UnauthorizedActionException with {
#   print "You are not authorized to view ticket\n";
# } catch RT::Client::REST::Exception with {
#   # something went wrong.
# };

# in the meantime, we'll do it with webisoget, clunky but works

# tickets in admin queue
my $admin_tickets_REST = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/search/ticket?query=Queue=%27mpc-admin-request%27"`;
my @lines = split /\n/, $admin_tickets_REST;
my @ticket_ids;
foreach $line (@lines) {
  my ($id) = $line =~ /^(\d+)\:/;
  push @ticket_ids, $id if $id;
} 
print "Retrieved ticket IDs for mpc-admin-request queue.\n";

# loop over tickets, getting properties and transaction history
foreach $tid (sort {$a <=> $b} @ticket_ids) {
  print "Processing $tid...\n";
  my $propstr = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/ticket/$tid/show"`;
  $propstr = strip_header(\$propstr);
  my $props = parse_props(\$propstr);
  my $historystr = `./webisoget-2.8.4/webisoget -text -formfile fran.login -url "https://rt.cla.umn.edu/REST/1.0/ticket/$tid/history?format=l"`;
  $historystr = strip_header(\$historystr);
  my @transactions = parse_history(\$historystr);
  print Dumper(\@transactions);
}

sub strip_header {
  my $strref = shift;
  $str = $$strref;
  $str =~ s/^.*?\n//;
  $str =~ s/^.*?\n//;
  return $str;
}

sub parse_props {
  my $props = shift;
  open my $fh, '<', $props;
  my %prophash;
  while (<$fh>) {
    if (($field, $value) = /(.*?)\:\s+(.*?)\n/) {
      $prophash{$field} = $value;
    }
  }
  close $fh;
  return \$prophash;
}

sub parse_history {
  my $history = shift;
  my @items = split /^--/, $$history;
  my @transactions;
  foreach my $item (@items) {
    open my $fh, '<', \$item;
    my %transhash;
    while (<$fh>) {
      if (($field, $value) = /^(\S*?)\:\s+(.*?)\n/) {
        $transhash{$field} = $value;
      }
    }
    close $fh;
    push @transactions, \%transhash;
  }
  return @transactions;
}


