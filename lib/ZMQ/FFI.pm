package ZMQ::FFI;

# ABSTRACT: version agnostic Perl bindings for zeromq using ffi

use strict;
use warnings;

use ZMQ::FFI::Util qw(zmq_soname zmq_version valid_soname);
use Carp;

use Import::Into;

sub import {
    my ($pkg, @import_args) = @_;

    my $target = caller;
    ZMQ::FFI::Constants->import::into($target, @import_args);
}

sub new {
    my ($self, %args) = @_;

    if ($args{soname}) {
        unless ( valid_soname($args{soname}) ) {
            die "Failed to load '$args{soname}', is it on your loader path?";
        }
    }
    else {
        $args{soname} = zmq_soname( die => 1 );
    }

    my ($major, $minor) = zmq_version($args{soname});

    if ($major == 2) {
        require ZMQ::FFI::ZMQ2::Context;
        return ZMQ::FFI::ZMQ2::Context->new(%args);
    }
    elsif ($major == 3) {
        require ZMQ::FFI::ZMQ3::Context;
        return ZMQ::FFI::ZMQ3::Context->new(%args);
    }
    else {
	if ($major == 4 and $minor == 0) {
            require ZMQ::FFI::ZMQ4::Context;
            return ZMQ::FFI::ZMQ4::Context->new(%args);
        }
        else {
            require ZMQ::FFI::ZMQ4_1::Context;
            return ZMQ::FFI::ZMQ4_1::Context->new(%args);
        }
    }
}

1;

__END__

=head1 SYNOPSIS

    #### send/recv ####

    use v5.10;
    use ZMQ::FFI qw(ZMQ_REQ ZMQ_REP);

    my $endpoint = "ipc://zmq-ffi-$$";
    my $ctx      = ZMQ::FFI->new();

    my $s1 = $ctx->socket(ZMQ_REQ);
    $s1->connect($endpoint);

    my $s2 = $ctx->socket(ZMQ_REP);
    $s2->bind($endpoint);

    $s1->send('ohhai');

    say $s2->recv();
    # ohhai


    #### pub/sub ####

    use v5.10;
    use ZMQ::FFI qw(ZMQ_PUB ZMQ_SUB);
    use Time::HiRes q(usleep);

    my $endpoint = "ipc://zmq-ffi-$$";
    my $ctx      = ZMQ::FFI->new();

    my $s = $ctx->socket(ZMQ_SUB);
    my $p = $ctx->socket(ZMQ_PUB);

    $s->connect($endpoint);
    $p->bind($endpoint);

    # all topics
    {
        $s->subscribe('');

        until ($s->has_pollin) {
            # compensate for slow subscriber
            usleep 100_000;
            $p->send('ohhai');
        }

        say $s->recv();
        # ohhai

        $s->unsubscribe('');
    }

    # specific topics
    {
        $s->subscribe('topic1');
        $s->subscribe('topic2');

        until ($s->has_pollin) {
            usleep 100_000;
            $p->send('topic1 ohhai');
            $p->send('topic2 ohhai');
        }

        while ($s->has_pollin) {
            say join ' ', $s->recv();
            # topic1 ohhai
            # topic2 ohhai
        }
    }


    #### multipart ####

    use v5.10;
    use ZMQ::FFI qw(ZMQ_DEALER ZMQ_ROUTER);

    my $endpoint = "ipc://zmq-ffi-$$";
    my $ctx      = ZMQ::FFI->new();

    my $d = $ctx->socket(ZMQ_DEALER);
    $d->set_identity('dealer');

    my $r = $ctx->socket(ZMQ_ROUTER);

    $d->connect($endpoint);
    $r->bind($endpoint);

    $d->send_multipart([qw(ABC DEF GHI)]);

    say join ' ', $r->recv_multipart;
    # dealer ABC DEF GHI


    #### nonblocking ####

    use v5.10;
    use ZMQ::FFI qw(ZMQ_PUSH ZMQ_PULL);
    use AnyEvent;
    use EV;

    my $endpoint = "ipc://zmq-ffi-$$";
    my $ctx      = ZMQ::FFI->new();
    my @messages = qw(foo bar baz);


    my $pull = $ctx->socket(ZMQ_PULL);
    $pull->bind($endpoint);

    my $fd = $pull->get_fd();

    my $recv = 0;
    my $w = AE::io $fd, 0, sub {
        while ( $pull->has_pollin ) {
            say $pull->recv();
            # foo, bar, baz

            $recv++;
            if ($recv == 3) {
                EV::break();
            }
        }
    };


    my $push = $ctx->socket(ZMQ_PUSH);
    $push->connect($endpoint);

    my $sent = 0;
    my $t;
    $t = AE::timer 0, .1, sub {
        $push->send($messages[$sent]);

        $sent++;
        if ($sent == 3) {
            undef $t;
        }
    };

    EV::run();


    #### specifying versions ####

    use ZMQ::FFI;

    # 2.x context
    my $ctx = ZMQ::FFI->new( soname => 'libzmq.so.1' );
    my ($major, $minor, $patch) = $ctx->version;

    # 3.x context
    my $ctx = ZMQ::FFI->new( soname => 'libzmq.so.3' );
    my ($major, $minor, $patch) = $ctx->version;


=head1 DESCRIPTION

ZMQ::FFI exposes a high level, transparent, OO interface to zeromq independent
of the underlying libzmq version.  Where semantics differ, it will dispatch to
the appropriate backend for you.  As it uses ffi, there is no dependency on XS
or compilation.

As of 1.00 ZMQ::FFI is implemented using L<FFI::Platypus>. This version has
substantial performance improvements and you are encouraged to use 1.00 or
newer.

=head1 CONTEXT API

=head2 new

    my $ctx = ZMQ::FFI->new(%options);

returns a new context object, appropriate for the version of
libzmq found on your system. It accepts the following optional attributes:

=head3 options

=over 4

=item threads

zeromq thread pool size. Default: 1

=item max_sockets

I<requires zmq E<gt>= 3.x>

max number of sockets allowed for context. Default: 1024

=item soname

    ZMQ::FFI->new( soname => '/path/to/libzmq.so' );
    ZMQ::FFI->new( soname => 'libzmq.so.3' );

specify the libzmq library name to load.  By default ZMQ::FFI will first try
the generic soname for the system, then the soname for each version of zeromq
(e.g. libzmq.so.3). C<soname> can also be the path to a particular libzmq so
file

It is technically possible to have multiple contexts of different versions in
the same process, though the utility of doing such a thing is dubious

=back

=head2 version

    my ($major, $minor, $patch) = $ctx->version();

return the libzmq version as the list C<($major, $minor, $patch)>

=head2 get

I<requires zmq E<gt>= 3.x>

    my $threads = $ctx->get(ZMQ_IO_THREADS)

get a context option value

=head2 set

I<requires zmq E<gt>= 3.x>

    $ctx->set(ZMQ_MAX_SOCKETS, 42)

set a context option value

=head2 socket

    my $socket = $ctx->socket(ZMQ_REQ)

returns a socket of the specified type. See L</SOCKET API> below

=head2 proxy

    $ctx->proxy($frontend, $backend);

    $ctx->proxy($frontend, $backend, $capture);

sets up and runs a C<zmq_proxy>. For zmq 2.x this will use a C<ZMQ_STREAMER>
device to simulate the proxy. The optional C<$capture> is only supported for
zmq E<gt>= 3.x however

=head2 device

I<zmq 2.x only>

    $ctx->device($type, $frontend, $backend);

sets up and runs a C<zmq_device> with specified frontend and backend sockets

=head2 destroy

destroy the underlying zmq context. In general you shouldn't have to call this
directly as it is called automatically for you when the object gets reaped

See L</CLEANUP> below

=head1 SOCKET API

The following API is available on socket objects created by C<$ctx-E<gt>socket>.

For core attributes and functions, common across all versions of zeromq,
convenience methods are provided. Otherwise, generic get/set methods are
provided that will work independent of version.

As attributes are constantly being added/removed from zeromq, it is unlikely
the 'static' accessors will grow much beyond the current set.

=head2 version

    my ($major, $minor, $patch) = $socket->version();

same as Context C<version> above

=head2 connect

    $socket->connect($endpoint);

does socket connect on the specified endpoint

=head2 disconnect

I<requires zmq E<gt>= 3.x>

    $socket->disconnect($endpoint);

does socket disconnect on the specified endpoint

=head2 bind

    $socket->bind($endpoint);

does socket bind on the specified endpoint

=head2 unbind

I<requires zmq E<gt>= 3.x>

    $socket->unbind($endpoint);

does socket unbind on the specified endpoint

=head2 get_linger, set_linger

    my $linger = $socket->get_linger();

    $socket->set_linger($millis);

get or set the socket linger period. Default: 0 (no linger)

See L</CLEANUP> below

=head2 get_identity, set_identity

    my $ident = $socket->get_identity();

    $socket->set_identity($ident);

get or set the socket identity for request/reply patterns

=head2 get_fd

    my $fd = $socket->get_fd();

get the file descriptor associated with the socket

=head2 get

    my $option_value = $socket->get($option_name, $option_type);

    my $linger = $socket->get(ZMQ_LINGER, 'int');

generic method to get the value for any socket option. C<$option_type> is the
type associated with C<$option_value> in the zeromq API (C<zmq_getsockopt> man
page)

=head2 set

    $socket->set($option_name, $option_type, $option_value);

    $socket->set(ZMQ_IDENTITY, 'binary', 'foo');

generic method to set the value for any socket option.  C<$option_type> is the
type associated with C<$option_value> in the zeromq API (C<zmq_setsockopt> man
page)

=head2 subscribe

    $socket->subscribe($topic);

add C<$topic> to the subscription list

=head2 unsubscribe

    $socket->unsubscribe($topic);

remove C<$topic> from the subscription list

=head2 send

    $socket->send($msg);

    $socket->send($msg, $flags);

sends a message using the optional flags

=head2 send_multipart

    $socket->send($parts_aref);

    $socket->send($parts_aref, $flags);

given an array ref of message parts, sends the multipart message using the
optional flags. ZMQ_SNDMORE semantics are handled for you

=head2 recv

    my $msg = $socket->recv();

    my $msg = $socket->recv($flags);

receives a message using the optional flags

=head2 recv_multipart

    my @parts = $socket->recv_multipart();

    my @parts = $socket->recv_multipart($flags);

receives a multipart message, returning an array of parts. ZMQ_RCVMORE
semantics are handled for you

=head2 has_pollin, has_pollout

    while ( $socket->has_pollin ) { ... }

checks ZMQ_EVENTS for ZMQ_POLLIN and ZMQ_POLLOUT respectively, and returns
true/false depending on the state

=head2 close

close the underlying zmq socket. In general you shouldn't have to call this
directly as it is called automatically for you when the object gets reaped

See L</CLEANUP> below

=head2 die_on_error

    $socket->die_on_error(0);

    $socket->die_on_error(1);

controls whether error handling should be exceptional or not. This is set to
true by default. See L</ERROR HANDLING> below

=head2 has_error

returns true or false depending on whether the last socket operation had an
error. This is really just an alias for C<last_errno>

=head2 last_errno

returns the system C<errno> set by the last socket operation, or 0 if there
was no error

=head2 last_strerror

returns the human readable system error message associated with the socket
C<last_errno>

=head1 CLEANUP

With respect to cleanup C<ZMQ::FFI> follows either the L<zeromq guide|http://zguide.zeromq.org/page:all#Making-a-Clean-Exit>
recommendations or the behavior of other zmq bindings.
That is:

=over 4

=item * it uses 0 linger by default (this is the default used by L<czmq|https://github.com/zeromq/czmq> and L<jzmq|https://github.com/zeromq/jzmq>)

=item * during object destruction it will call close/destroy for you

=item * it arranges the reference hierarchy such that sockets will be properly
      cleaned up before their associated contexts

=item * it detects fork/thread situations and ensures sockets/contexts are only
      cleaned up in their originating process/thread

=item * it guards against double closes/destroys

=back

Given the above you're probably better off letting C<ZMQ::FFI> handle cleanup
for you. But if for some reason you want to do explicit cleanup yourself you
can. All the below will accomplish the same thing:

    # implicit cleanup
    {
        my $context = ZMQ::FFI->new();
        my $socket  = $ctx->socket($type);
        ...
        # close/destroy called in destructors at end of scope
    }

    # explicit cleanup
    $socket->close();
    $context->destroy();

    # ditto
    undef $socket;
    undef $context;

Regarding C<linger>, you can always set this to a value you prefer if
you don't like the default. Once set the new value will be used when the
socket is subsequently closed (either implicitly or explicitly):

    $socket->set_linger(-1); # infinite linger
                             # $context->destroy will block forever
                             # (or until all pending messages have been sent)

=head1 ERROR HANDLING

By default, ZMQ::FFI checks the return codes of underlying zmq functions for
you, and in the case of an error it will die with the human readable system
error message.

    $ctx->socket(-1);
    # dies with 'zmq_socket: Invalid argument'

Usually this is what you want, but not always. Some zmq operations can return
errors that are not fatal and should be handled. For example using
C<ZMQ_DONTWAIT> with send/recv can return C<EAGAIN> and simply means try
again, not die.

For situations such as this you can turn off exceptional error handling by
setting C<die_on_error> to 0. It is then for you to check and manage any zmq
errors by checking C<last_errno>:

    use Errno qw(EAGAIN);

    my $ctx = ZMQ::FFI->new();
    my $s   = $ctx->socket(ZMQ_DEALER);
    $s->bind('tcp://*:7200');

    $s->die_on_error(0); # turn off exceptional error handling

    while (1) {
        my $msg = $s->recv(ZMQ_DONTWAIT);

        if ($s->last_errno == EAGAIN) {
            sleep 1;
        }
        elsif ($s->last_errno) {
            die $s->last_strerror;
        }
        else {
            warn "recvd: $msg";
            last;
        }
    }

    $s->die_on_error(1); # turn back on exceptional error handling

=head1 FFI VS XS PERFORMANCE

ZMQ::FFI uses L<FFI::Platypus> on the backend. In addition to a friendly,
usable interface, FFI::Platypus's killer feature is C<attach>. C<attach> makes
it possible to bind ffi functions in memory as first class Perl xsubs. This
results in dramatic performance gains and gives you the flexibility of ffi
with performance approaching that of XS.

Testing indicates FFI::Platypus xsubs are around 30% slower than "real" XS
xsubs. That may sound like a lot, but to put it in perspective that means, for
zeromq, the XS bindings can send 10 million messages 1-2 seconds faster than
the ffi ones.

If you really care about 1-2 seconds over 10 million messages you should be
writing your solution in C anyways. An equivalent C implementation will be
several I<hundred> percent faster or more.

Keep in mind also that the small speed bump you get using XS can easily be
wiped out by crappy and poorly optimized Perl code.

Now that Perl finally has a great ffi interface, it is hard to make the case
to continue using XS. The slight speed bump just isn't worth giving up the
convenience, flexibility, and portability of ffi.

You can find the detailed performance results that informed this section at:
L<https://gist.github.com/calid/17df5bcfb81c83786d6f>

=head1 BUGS

C<ZMQ::FFI> is free as in beer in addition to being free as in speech. While
I've done my best to ensure it's tasty, high quality beer, it probably isn't perfect.
If you encounter problems, or otherwise see room for improvement, please open
an issue (or even better a pull request!) on L<github|https://github.com/calid/zmq-ffi>

=head1 SEE ALSO

=for :list
* L<ZMQ::FFI::Constants>
* L<ZMQ::FFI::Util>
* L<FFI::Platypus>
* L<FFI::Raw>
* L<ZMQ::LibZMQ3>
