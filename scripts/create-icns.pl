#!/usr/bin/perl
use strict;
use warnings;

my ($iconset, $output) = @ARGV;
die "Usage: $0 ICONSET OUTPUT.icns\n" unless defined $iconset && defined $output;

my @resources = (
    [ 'icp4', 'icon_16x16.png' ],
    [ 'ic11', 'icon_16x16@2x.png' ],
    [ 'icp5', 'icon_32x32.png' ],
    [ 'ic12', 'icon_32x32@2x.png' ],
    [ 'ic07', 'icon_128x128.png' ],
    [ 'ic13', 'icon_128x128@2x.png' ],
    [ 'ic08', 'icon_256x256.png' ],
    [ 'ic14', 'icon_256x256@2x.png' ],
    [ 'ic09', 'icon_512x512.png' ],
    [ 'ic10', 'icon_512x512@2x.png' ],
);

my $body = '';
for my $resource (@resources) {
    my ($type, $name) = @$resource;
    my $path = "$iconset/$name";
    open my $input, '<:raw', $path or die "Cannot read $path: $!\n";
    local $/;
    my $png = <$input>;
    close $input;
    die "Invalid PNG resource: $path\n" unless substr($png, 0, 8) eq "\x89PNG\r\n\x1a\n";
    $body .= $type . pack('N', length($png) + 8) . $png;
}

my $icns = 'icns' . pack('N', length($body) + 8) . $body;
open my $out, '>:raw', $output or die "Cannot write $output: $!\n";
print {$out} $icns;
close $out or die "Cannot close $output: $!\n";

