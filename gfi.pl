#!/usr/bin/perl

# take a stream of JSON strings or progress messages on STDIN
# and writes objects directly to the repo
#
# JSON format [ commit string , sha1 , file path ]
#
# commit string: everything but the "tree" and "parent" lines
# and the object header of a git commit object
#
# sha1: the 20 bytes binary sha1 of the modified | added file
#
# file path: the '/' seperated path of the file starting at the
# top tree

use feature ':5.10';

use strict;
use warnings;
require bytes;

use FindBin;
use lib "$FindBin::Bin";

use JSON::XS;
use Deep::Hash::Utils qw(nest deepvalue);

use Encode;

use Git::Tree;
use Git::Pack;
use Git::Common;

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');
binmode(STDIN, ':utf8');

STDOUT->autoflush(1);

my %OPTS = (
    pack_size => int(1.8 * 1024**3),
    delta_depth => 100,
    max_objects => int(5 * 1024**2),
);

my $tree = {};
my $last_commit;
my $GIT = '.git/objects';
my $pack = Git::Pack->new;
my %may_delta;

while (my $line = <>) {
    if (substr($line, 0, 9) eq 'progress ') {
        print $line;
        next;
    }

    my $rev = decode_json($line);

    my @path = split qr '/', Encode::encode_utf8($rev->[2]);
    my $file = pop @path;

    my $twig = get_tree($tree, @path);
    $twig->{_tree}->add(['100644', $file, pack('H*',$rev->[1]) ]  );
    
    my $sha1;
    while(@path) {
        $sha1 = write_tree($twig, \@path);
        my $dir = pop @path;
        $twig = get_tree($tree, @path);
        $twig->{_tree}->add(['40000', $dir, $sha1]);
    }
    $sha1 = write_tree($twig, \@path);

    my $commit = get_commit( $last_commit, $sha1, Encode::encode_utf8($rev->[0]) );
    my ($bin, $ofs) = $pack->maybe_write('commit', $commit);


    $last_commit = unpack('H*', $bin);

    if ($pack->{count} >= $OPTS{max_objects} || $pack->{outbytes} >= $OPTS{pack_size}) {
        $pack->breakpoint;
        undef %may_delta;
        open my $ref, '>', Git::Common::repo('refs/heads/master')
            or die 'cannot open "master"';
        print {$ref} $last_commit or die 'cannot write to "master"';
        close($ref) or die 'cannot close "master"';
    };
}

$pack->close;

open my $ref, '>', Git::Common::repo('refs/heads/master') or die 'cannot open "master"';
print {$ref} $last_commit or die 'cannot write to "master"';
close($ref) or die 'cannot close "master"';



sub get_tree {
    my ($tree, @path) = @_;
    my $t = deepvalue($tree, @path);
    if (!$t) {
        $t = {
            _tree => Git::Tree->new,
            _sha1 => undef,
            _ofs => undef
        };
        nest($tree, @path, $t);
    }
    if (!$t->{_tree}) {
        $t->{_tree} = Git::Tree->new;
        $t->{_sha1} = undef;
        $t->{_ofs} = undef;
    }
    return $t;
}

sub write_tree {
    my ($twig, $path_ref) = @_;

    my $path = join( '/', @$path_ref );
    if ($may_delta{$path} && $may_delta{$path} < $OPTS{delta_depth} && $twig->{_sha1} && $twig->{_ofs}) {
        my $obj = $twig->{_tree}->{full};
        my $delta = Faster::create_delta($twig->{_old}, $obj, $twig->{_tree}->{diff});

        my ($sha1, $ofs) = $pack->delta_write('tree', $obj, $delta, $twig->{_ofs});

        #dump_info('delta', $diff, $delta, $obj) if $ofs == 9720913;

        $twig->{_sha1} = $sha1;
        $twig->{_ofs} = $ofs;
        $twig->{_old} = bytes::length($obj);
        $may_delta{$path}++;
    }
    else {
        my $obj = $twig->{_tree}->{full};
        my ($sha1, $ofs) = $pack->maybe_write('tree', $obj);

        $twig->{_sha1} = $sha1;
        $twig->{_ofs} = $ofs;
        $twig->{_old} = bytes::length($obj);
        $may_delta{$path} = 1;
    }
    my $sha1 = $twig->{_sha1};
    return $sha1;
}



sub get_commit {
    my ($parent, $sum, $msg) = @_;

    my $content = sprintf qq{tree %s\n%s%s},
        unpack('H*', $sum),
        (defined $parent ? qq{parent $parent\n} : ''),
        $msg;

    return $content;
}

sub dump_info {
    my ($type, $diff, $delta, $obj) = @_;
    require Data::Dump;
    say STDERR $type;
    say STDERR Data::Dump::dump($diff);
    say STDERR Data::Dump::quote($delta);
    say STDERR Data::Dump::quote($obj);

}

