# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# SlackPlugin is Copyright (C) 2020 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::SlackPlugin::Core;

use strict;
use warnings;

use Foswiki::Func ();
use WebService::Slack::WebApi ();
use Error qw(:try);
#use Data::Dump qw(dump);

use constant TRACE => 0;
use constant SLACK_COLOR_OK      => '#2eb886';    # green
use constant SLACK_COLOR_INFO    => '#4b42f4';    # blue
use constant SLACK_COLOR_ERROR   => '#cc0000';    # red
use constant SLACK_COLOR_WARNING => '#f5ca46';    # yellowish

sub new {
  my $class = shift;

  my $this = bless({
    @_
  }, $class);

  return $this;
}

sub finish {
  my $this = shift;

  undef $this->{_slack};
}

sub slack {
  my ($this, $conn) = @_;

  $conn ||= 'default';

  unless ($this->{_slack}{$conn}) {
    my $token = $Foswiki::cfg{SlackPlugin}{Connections}{$conn};
    $this->{_slack}{$conn} = WebService::Slack::WebApi->new(token => $token) if $token; 
  }

  return $this->{_slack}{$conn};
}

sub call {
  my ($this, $method, $params) = @_;

  _writeDebug("calling ".($method//'undef'));

  return unless $method;

  # messages
  return $this->post_ok($params) if $method eq 'ok';
  return $this->post_warning($params) if $method eq 'warning';
  return $this->post_info($params) if $method eq 'info';
  return $this->post_error($params) if $method eq 'error';
  return $this->post_message($params) if $method eq 'chat.postMessage';

  # other methods
  my $slack = $this->slack($params->{conn});
  return unless $slack;

  return $slack->api->test(%$params) if $method eq 'api.test';
  return $slack->auth->test(%$params) if $method eq 'auth.test';
  return $slack->channels->list(%$params) if $method eq 'channels.list';
  return $slack->channels->invite(%$params) if $method eq 'channels.invite';

  #return $this->slack->users->admin->invite(%$params) if $method eq 'users.admin.invite';

  _writeDebug("... unknown method");
  return;
}

sub post_ok {
  my ($this, $params) = @_;

  $params->{color} = SLACK_COLOR_OK;
  return $this->post_message($params);
}

sub post_warning {
  my ($this, $params) = @_;

  $params->{color} = SLACK_COLOR_WARNING;
  return $this->post_message($params);
}

sub post_info {
  my ($this, $params) = @_;

  $params->{color} = SLACK_COLOR_INFO;
  return $this->post_message($params);
}

sub post_error {
  my ($this, $params) = @_;

  $params->{color} = SLACK_COLOR_ERROR;
  return $this->post_message($params);
}

sub post_message {
  my ($this, $params) = @_;

  my $text = $params->{text};
  my $color = $params->{color};
  my $title = $params->{title};

  return unless defined $text && $text ne "";

  my $slack = $this->slack($params->{conn});
  return unless $slack;

  my $attachments = {
    text => $text,
    mrkdwn_in => [qw/text title/],
  };

  $attachments->{title} = $title if defined $title;
  $attachments->{color} = $color if defined $color;

  return $slack->chat->post_message(
    channel => $params->{channel} || "general",
    attachments => [$attachments]
  );
}

sub SLACK {
  my ($this, $session, $params, $topic, $web) = @_;

  _writeDebug("called SLACK()");

  my $method = $params->{_DEFAULT};
  my $response;
  my $error;

  try {
    $response = $this->call($method, $params);
  } catch Error::Simple with {
    $error = shift;
    print STDERR "ERROR: ".$error."\n";
    #_writeDebug("ERROR: ".$error);
  };

  return _inlineError($error) if defined $error;

  _writeDebug("response:");
  _writeDebug($response) if $response;

  my $format = $params->{format};
  my $result;
  if (defined $format) {
    $result = $this->formatResponse($format, $response);
  } else {
    $result = _stringifyHash($response);
  }
  
  return Foswiki::Func::decodeFormatTokens($result);
}

sub formatResponse {
  my ($this, $format, $response) = @_;
  
  my $result = $format;
  
  foreach my $key (keys %$response) {
    next if $key =~ /^(?:token|args)$/;
    my $val = _stringify($response->{$key});
    $result =~ s/\$$key\b/$val/g;
  }

  return $result;
}

sub _stringify {
  my ($val, $depth) = @_;

  $depth ||= 1;
  _writeDebug("called _stringify($val, $depth)");
  my $ref = ref($val);
  return $val unless $ref;

  return _stringifyArray($val, $depth) if $ref eq 'ARRAY';
  return _stringifyHash($val, $depth) if $ref eq 'HASH';
  return $val if $ref =~ /boolean/i;

  _writeDebug("Hm, unknown ref=$ref");
  return $val;
}

sub _stringifyArray {
  my ($arr, $depth) = @_;

  $depth ||= 1;
  _writeDebug("called _stringifyArr($arr, $depth)");

  my @result = ();
  foreach my $val (@$arr) {
    my $val = _stringify($val, $depth+1);
    push @result, "   " x $depth . "1 ".$val if defined $val && $val ne '';
  }

  return "" unless @result;
  return "\n".join("\n", @result);
}

sub _stringifyHash {
  my ($hash, $depth) = @_;

  return "" unless defined $hash;

  $depth ||= 1;
  _writeDebug("called _stringifyHash($hash, $depth)");

  my @result = ();
  foreach my $key (sort keys %$hash) {
    next if $key =~ /^(?:token|_.*)$/;
    my $val = _stringify($$hash{$key}, $depth+1);
    push @result, "   " x $depth . "* $key: $val" if defined $val && $val ne '';
  }

  return "" unless @result;
  return "\n".join("\n", @result);
}

sub _writeDebug {
  my $msg = shift;

  return unless TRACE;

  #$msg = dump($msg) if ref($msg);

  print STDERR "SlackPlugin::Core - $msg\n";
}

sub _inlineError {
  my $msg = shift;

  $msg =~ s/ at .*$//s;
  $msg =~ s/\.\.\. found//;
  $msg =~ s/[\n\r]+/ /gs;
  return "<span class='foswikiAlert'>$msg</span>";
}


1;
