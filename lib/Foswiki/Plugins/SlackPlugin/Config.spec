# ---+ Extensions
# ---++ SlackPlugin
# This is the configuration used by the <b>SlackPlugin</b>.

# **BOOLEAN**
$Foswiki::cfg{SlackPlugin}{Debug} = 0;

# **STRING**
$Foswiki::cfg{SlackPlugin}{Team} = 'foswiki';

# **PERL**
$Foswiki::cfg{SlackPlugin}{Connections} = '{
  "default" => "token foo"
}';

1;
