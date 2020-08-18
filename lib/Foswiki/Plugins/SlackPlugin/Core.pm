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

  throw Error::Simple("unknown connection") unless $this->{_slack}{$conn};

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

  return $slack->conversations->list(%$params) if $method eq 'conversations.list';
  return $slack->conversations->invite(%$params) if $method eq 'conversations.invite';

  return $slack->users->list(%$params) if $method eq 'users.list';

  # deprecated
  #return $slack->channels->list(%$params) if $method eq 'channels.list';
  #return $slack->channels->invite(%$params) if $method eq 'channels.invite';

  #return $this->slack->users->admin->invite(%$params) if $method eq 'users.admin.invite';

  throw Error::Simple("unknown method '$method'");
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
  my $attachments = {
    text => $text,
    mrkdwn_in => [qw/text title/],
  };

  $attachments->{title} = $title if defined $title;
  $attachments->{color} = $color if defined $color;

  return $slack->chat->post_message(
    channel => $params->{channel} // "#general",
    attachments => [$attachments]
  );
}

sub init {
  my ($this, $params, $web, $topic) = @_;

  $this->{_params} = $params;
  $this->{_web} = $web;
  $this->{_topic} = $topic;
}

sub SLACK {
  my ($this, $session, $params, $topic, $web) = @_;

  _writeDebug("called SLACK()");

  $this->init($params, $web, $topic);

  my $method = $params->{_DEFAULT};
  return "" unless $method;

  my $response;
  my $error;


  try {
    $response = $this->call($method, $params);
    #_writeDebug("response=".dump($response));
  } catch Error::Simple with {
    $error = shift;
    print STDERR "ERROR: ".$error."\n";
    #_writeDebug("ERROR: ".$error);
  };

  return _inlineError($error) if defined $error;

  if (defined $response->{error}) {
    my $error = $response->{error};
    $error = "missing scope: $response->{needed} required" if defined $response->{needed} && $error eq 'missing_scope';
    return _inlineError($error);
  } 

  my $result;

  my $format = $params->{format};
  if (defined $format) {
    $result = $format;
    $result =~ s/\$([a-zA-Z0-9\._]+)\b/$this->formatHash($response, $1)/ge;
    $result =~ s/\$formatDate\((\d*?)(?:, *(.*?))?\)/_formatTime($1, $2)/ge;
    $result =~ s/\$formatTime\((\d*?)\)/_formatTime($1, $Foswiki::cfg{DateTimePlugin}{DefaultDateTimeFormat} || $Foswiki::cfg{DefaultDateFormat}.' - $hour:$min')/ge;
  } else {
    #$result = $this->formatResult($response);
    $result = _stringify($response);
  }

  my $clear = $params->{clear} // '';
  foreach my $c (split(/\s*,\s*/, $clear)) {
    $result =~ s/\$$c//g;
  }

  
  return Foswiki::Func::decodeFormatTokens($result);
}

sub formatResult {
  my ($this, $obj) = @_;

  _writeDebug("called formatResult($obj)");

  my @result = ();
  foreach my $key (sort keys %$obj) {
    next if $key =~ /^(?:token|ok|cache_ts|_.*|response_metadata)$/;
    my $line = $this->formatHash($obj, $key);
    push @result, $line if defined $line && $line ne "";
  }
  return "" unless scalar(@result);

  my $sep = $this->{_params}{separator} // ', ';
  my $header = $this->{_params}{header} // '';
  my $footer = $this->{_params}{footer} // '';

  return $header.join($sep, @result).$footer;
}

sub formatHash {
  my ($this, $obj, $key) = @_;

  return '' unless defined $key && defined $obj;

  _writeDebug("called formatHash($obj, $key)");

  return "\n" if $key eq 'n';
  return '%' if $key eq 'percnt';
  return '$' if $key eq 'dollar';

  my $subKey;
  my $origKey = $key;

  if ($key =~ /^(.*)?\.(.*)$/) {
    $key = $1;
    $subKey = $2;
  }

  if (ref($obj) eq 'HASH') {

    #_writeDebug("... hash");
    my $val = $obj->{$key};
    return $this->formatHash($val, $subKey) if defined $subKey;
    return $this->formatArray($val, $key) if ref($val) eq 'ARRAY';
    return $this->formatHash($val, $key) if ref($val) eq 'HASH';

    return $val if defined($val);
  } elsif (ref($obj) eq 'ARRAY') {
    #_writeDebug("... array");

    return $this->formatArray($obj, $key);
  }

  #_writeDebug("... not defined: $origKey");
  return '$' . $origKey;
}

sub formatArray {
  my ($this, $obj, $key) = @_;

  return "" unless defined $key;

  _writeDebug("called formatArray($obj, $key)");

  my $header = $this->{_params}{$key . "_header"} // '';
  my $footer = $this->{_params}{$key . "_footer"} // '';
  my $separator = $this->{_params}{$key . "_separator"} // ' ';
  my $format = $this->{_params}{$key . "_format"} // '$name';

  my @result = ();
  my $regex;
  foreach my $item (@$obj) {
    my $line = $format;
    if (ref($item)) {
      $line =~ s/\$([a-zA-Z0-9\._]+)\b/$this->formatHash($item, $1)/ge;
    } else {
      $line =~ s/\$$key\b/$item/g;
    }
    push @result, $line if $line ne "";
  }

  return "" unless @result;
  return $header . join($separator, @result) . $footer;
}

sub _formatTime {
  my ($epoch, $format) = @_;

  return "" unless $epoch;

  my $result;
  try {
    $result = Foswiki::Func::formatTime($epoch, $format);
  } catch Error with {};

  $result ||= '';

  return $result;
}

sub _stringify {
  my ($val, $depth) = @_;

  $depth ||= 1;
  $val //= 'undef';
  #_writeDebug("called _stringify($val, $depth)");
  my $ref = ref($val);
  return $val unless $ref;

  return _stringifyArray($val, $depth) if $ref eq 'ARRAY';
  return _stringifyHash($val, $depth) if $ref eq 'HASH';

  _writeDebug("Hm, unknown ref=$ref");
  return $val;
}

sub _stringifyArray {
  my ($arr, $depth) = @_;

  $depth ||= 1;
  #_writeDebug("called _stringifyArr($arr, $depth)");

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
  #_writeDebug("called _stringifyHash($hash, $depth)");

  my @result = ();
  foreach my $key (sort keys %$hash) {
    next if $key =~ /^(?:token|ok|cache_ts|_.*|response_metadata)$/;
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
