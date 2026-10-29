#!/usr/bin/ruby
# Compatibility entrypoint for the original MapleStory opt-in tool and tests.
require_relative 'cyder-scrolling'
CyderMapleStoryScrolling = CyderScrolling
cyder_scrolling_cli if __FILE__ == $PROGRAM_NAME
