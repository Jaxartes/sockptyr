/* sockptyr_tests_bulk2.c
 * Copyright (c) 2019 Jeremy Dilatush
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY JEREMY DILATUSH AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL JEREMY DILATUSH OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/* This is a test program for the "sockptyr" application.
 *
 * To use:
 *      compile into a binary
 *      run the sockptyr GUI
 *      run this program w/ appropriate parameters (see below)
 *      interact with the GUI and watch this program's output
 *
 * This program occasionally creates/removes sockets, and continually
 * sends/receives data on them.  The data is weakly pseudorandom, coded
 * in such a way that it's easy to recognize it as our own and whether
 * it's been corrupted or not.
 *
 * Command line parameters:
 *      directory name in which to put sockets
 *      "typical" number of sockets to have at a time; max is twice this
 *      "typical" time (in seconds) between socket creation/removal
 *      "typical" delay (in seconds) between socket()/bind() & listen()
 *      "typical" delay (in seconds) before accept()
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/un.h>

static char *sockdir;
static int nslots;
static float opint, listdel, accdel;

/** ** ** utilities ** ** **/

/* full_write()
 * Wrapper around write() to find out string length and to write the whole
 * thing even if write() doesn't do it all at once.
 *
 * This is meant for error/status output.  If it, in turn, gets an error
 * it doesn't report it or abort but just keeps trying.
 */
ssize_t full_write(int fd, const char *buf)
{
    size_t got = buf ? strlen(buf) : 0;
    ssize_t wrote = 0;
    ssize_t wrote1;

    while (wrote < got) {
        wrote1 = write(fd, buf + wrote, got - wrote);
        if (wrote1 <= 0) {
            struct timespec ts;

            ts.tv_sec = 0;
            ts.tv_nsec = 250000000; /* 1/4 sec */
            nanosleep(&ts, NULL);
            continue;
        }
        wrote += wrote1;
    }

    return(wrote);
} 

/* tmsg()
 * Formats a time-stamped message and writes it to stderr.
 * A mutex is used to keep the threads from mixing with each other.
 */
static pthread_mutex_t tmsg_mutex;
static void tmsg(char *fmt, ...)
{
    struct timeval tv;
    char buf[512];
    va_list ap;

    pthread_mutex_lock(&tmsg_mutex);

    gettimeofday(&tv, NULL);
    strftime(buf, sizeof(buf), "%H:%M:%S", localtime(&tv.tv_sec));
    full_write(STDERR_FILENO, buf);

    snprintf(buf, sizeof(buf), ".%06u: ", (unsigned)tv.tv_usec);
    full_write(STDERR_FILENO, buf);

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    full_write(STDERR_FILENO, buf);

    buf[0] = '\n';
    buf[1] = '\0';
    full_write(STDERR_FILENO, buf);

    pthread_mutex_unlock(&tmsg_mutex);
}

/* fsleep() -- sleep for a floating point number of seconds */
void fsleep(float s)
{
    struct timespec ts, tsrem;

    ts.tv_sec = floor(s);
    ts.tv_nsec = floor((s - floor(s)) * 1e+9);
    for (;;) {
        tsrem = ts;
        if (nanosleep(&ts, &tsrem) >= 0) {
            return;
        } else if (errno == EINTR) {
            tsrem = ts;
        } else {
            tmsg("nanosleep() failed: %s", strerror(errno));
            _exit(1);
        }
    }    
}

static char status_ctl = 0; /* incremented when a status report is wanted */

/** ** ** detectable pseudorandom data sequences ** ** **/

/*
 * Defines 2**32 sequences of 2**32 8-byte values, repeated.  From a pair
 * of 8-byte values it's possible to identify what sequence you're on and
 * where on it you are, and from that you can verify even pieces of less
 * than 8 bytes.  This would usually *not* be a good thing in pseudorandom
 * number generation, but in this application it's desired.
 *
 * The sequence 'seq' consists of:
 *      encode(seq, 0)
 *      encode(seq, 1)
 *      encode(seq, 2)
 * and so on.
 *
 * The encoding algorithm is as follows:
 *      let ary[] be a sequence of 32-bit values used in this computation
 *      ary[0] := seq (number identifying the sequence)
 *      ary[1] := position in sequence
 *      ary[n+2] := ary[n] XOR (ary[n+1] * 3141)
 *      result := ary[6..7] represented in little endian byte order
 */

/* dpds_encode()
 * fill in 'data' from 'seq' & 'pos' as encode() in the algorithm above
 */
static inline void dpds_encode(u_int8_t *data, u_int32_t seq, u_int32_t pos)
{
    u_int32_t ary[8];
    int n;

    ary[0] = seq;
    ary[1] = pos;
    for (n = 0; n < 6; ++n) {
        ary[n+2] = ary[n] ^ (ary[n+1] * 3141);
    }

    for (n = 0; n < 8; ++n) {
        data[n] = (ary[6 + (n >> 2)] >> ((n & 3) << 3)) & 0xff;
    }
}

/* dpds_decode()
 * fill in 'seq' and 'pos' from 'data' as the reverse of dpds_encode()
 */
static inline void dpds_decode(u_int32_t *seq, u_int32_t *pos, u_int8_t *data)
{
    u_int32_t ary[8];
    int n;

    ary[6] = ary[7] = 0;
    for (n = 0; n < 8; ++n) {
        ary[6 + (n >> 2)] |= ((u_int32_t)data[n]) << ((n & 3) << 3);
    }
    for (n = 5; n >= 0; --n) {
        ary[n] = ary[n+2] ^ (ary[n+1] * 3141);
    }
    *seq = ary[0];
    *pos = ary[1];
}

#define DPDS_SIZE 8

/* dpds_consumer_state
 * dpds_consume()
 * Validate read DPDS data.  If we suddenly skip to a different place
 * in the stream, or a different stream entirely, report that.
 *
 * Parameters to dpds_consume():
 *      name -- string identifying the socket
 *      buf -- buffer holding received data
 *      got -- number of bytes in buf
 *      dcs -- dpds_consumer_state structure
 * Returns: New value for 'got' reflecting any bytes not consumed; those
 * bytes will have been moved to the head of 'buf'.
 */
struct dpds_consumer_state {
    u_int32_t seq; /* sequence identifier */
    u_int32_t pos; /* position within sequence */
};

int dpds_consume(char *sname, u_int8_t *buf, int got,
                 struct dpds_consumer_state *dcs)
{
    u_int32_t seq, pos, seq2, pos2;
    int at, fudge = 0;
    u_int8_t odd[DPDS_SIZE];

    for (at = 0; at + DPDS_SIZE <= got; ) {
        /* see when these 8 bytes decode as */
        dpds_decode(&seq, &pos, buf + at);

        /* is it what we expected? */
        if (seq == dcs->seq && pos == dcs->pos) {
            /* Yes. */
            dcs->pos++;
            at += DPDS_SIZE;
            continue;
        } else {
            /* No.  Maybe it's a new sequence.  Which might or might
             * not be aligned.  We need DPDS_SIZE * 2 bytes to tell.
             */
            if (at + DPDS_SIZE * 2 > got) {
                /* we don't have enough */
                break;
            }
            dpds_decode(&seq2, &pos2, buf + at + DPDS_SIZE);
            if (seq2 == seq && ((u_int32_t)(pos2 - pos)) == 1) {
                /* ok, got a match */
                if (fudge > 0) {
                    /* see whether the odd bytes look right */
                    dpds_encode(odd, seq, pos);
                    if (memcmp(buf + at - fudge, odd - fudge, fudge) != 0) {
                        /* nope */
                        tmsg("%s: %d bytes apparent garbage ignored",
                             sname, fudge);
                        fudge = 0;
                    }
                }
                tmsg("%s: jumped 0x%08lx/0x%08lx -> 0x%08lx/0x%08lx-%d",
                     sname,
                     (unsigned long)dcs->seq, (unsigned long)dcs->pos,
                     (unsigned long)seq, (unsigned long)pos,
                     (int)fudge);
                fudge = 0;
                dcs->seq = seq;
                dcs->pos = pos;
            } else {
                /* not aligned, so let's try adjusting by one byte */
                fudge++;
                if (fudge < DPDS_SIZE) {
                    at++;
                } else {
                    tmsg("%s: %d bytes apparent garbage ignored",
                         sname, fudge);
                    fudge = 0;
                }
            }
        }
    }

    if (at < got) {
        memmove(buf, buf + at, got - at);
        return(got - at);
    } else {
        return(0);
    }
}

/** ** ** handle a single socket slot, in a thread ** ** **/

/* information about a single one */
struct slot {
    pthread_t thread; /* the thread */
    int i; /* number distinct for each thread */
    unsigned short xsubi[3]; /* state for {e,n,j}rand48() for this thread */
};

/* slot_main() -- Main loop on one of our "slots".  Holds one socket except
 * when it doesn't.  Runs in a thread.
 */
static void *slot_main(void *sl_voidp)
{
    struct slot *sl = sl_voidp;
    long name_ctr = 0; /* counter for naming sockets */
    char sname[80]; /* socket filename */
    int lsok; /* listening socket */
    int csok; /* connected socket */
    struct sockaddr_un aun;
    struct pollfd pfd;
    int rv, f_flags, todo;
    struct timeval tnow, tend;
    float f;
    char status_ctl_mon = 0;
    u_int8_t rbuf[4096], wbuf[4096]; /* read & write buffers */
    int rgot, wgot; /* bytes in read & write buffers currently */
    long long received, sent; /* bytes total received/sent on this socket */
    u_int32_t txseq; /* sequence used for send */
    u_int32_t txpos; /* sequence position for send */
    int idle, first = 1;
    struct dpds_consumer_state dcs;
    struct stat sb;

    memset(&pfd, 0, sizeof(pfd));

    for (;;) {
        /* wait a bit before creating socket -- except the first time half
         * the time
         */
        if ((!first) || (nrand48(sl->xsubi) & 16)) {
            do {
                fsleep(erand48(sl->xsubi) * opint);
            } while (nrand48(sl->xsubi) & 16);
        }
        first = 0;

        /* create a socket */
        lsok = socket(AF_UNIX, SOCK_STREAM, 0);
        if (lsok < 0) {
            tmsg("socket() failed: %s", strerror(errno));
            _exit(1);
        }

        /* figure out socket name */
        memset(&aun, 0, sizeof(aun));
        aun.sun_family = AF_UNIX;
        snprintf(sname, sizeof(sname), "bulk2_%d_%d",
                 (int)sl->i, (int)name_ctr);
        ++name_ctr;
        snprintf(aun.sun_path, sizeof(aun.sun_path),
                 "%s/%s", sockdir, sname);

        /* is there a conflicting socket? if so delete it */
        if (stat(aun.sun_path, &sb) >= 0 && S_ISSOCK(sb.st_mode)) {
            tmsg("unlinking pre-existing socket %s", aun.sun_path);
            unlink(aun.sun_path);
        }

        /* bind the newly created socket to the name we chose */
        if (bind(lsok, (void *)&aun, sizeof(aun)) < 0) {
            tmsg("bind(%s/%s) failed: %s", sockdir, sname, strerror(errno));
            _exit(1);
        }
        tmsg("Created %s/%s", sockdir, sname);

        /* wait a bit then listen() on the socket */
        do {
            fsleep(erand48(sl->xsubi) * listdel);
        } while (nrand48(sl->xsubi) & 16);
        if (listen(lsok, 1) < 0) {
            tmsg("listen(%s/%s) failed: %s", sockdir, sname, strerror(errno));
            _exit(1);
        }
        tmsg("Listened on %s/%s", sockdir, sname);

        /* wait until we have a connection to accept() on the socket */
        pfd.fd = lsok;
        pfd.events = POLLIN;
        pfd.revents = 0;
        for (;;) {
            rv = poll(&pfd, 1, -1);
            if (rv < 0) {
                if (errno == EINTR) {
                    continue;
                } else {
                    tmsg("poll() failed: %s", strerror(errno));
                }
            }
            if (pfd.revents & POLLERR) {
                tmsg("poll(%s/%s) gave POLLERR", sockdir, sname);
                _exit(1);
            } else if (pfd.revents & POLLNVAL) {
                tmsg("poll(%s/%s) gave POLLNVAL", sockdir, sname);
                _exit(1);
            } else if (pfd.revents & POLLHUP) {
                tmsg("poll(%s/%s) gave POLLHUP", sockdir, sname);
                _exit(1);
            } else if (pfd.revents & POLLIN) {
                /* there's a connection to accept() */
                break;
            }
        }
        tmsg("Connection on %s/%s", sockdir, sname);

        /* wait a bit then accept() on the socket */
        do {
            fsleep(erand48(sl->xsubi) * accdel);
        } while (nrand48(sl->xsubi) & 16);
        csok = accept(lsok, NULL, NULL);
        if (csok < 0) {
            tmsg("accept(%s/%s) failed: %s", sockdir, sname, strerror(errno));
            _exit(1);
        }
        tmsg("Accepted connection on %s/%s", sockdir, sname);

        f_flags = fcntl(csok, F_GETFL);
        f_flags |= O_NONBLOCK;
        fcntl(csok, F_SETFL, f_flags);

        received = sent = 0;
        rgot = wgot = 0;
        txseq = dcs.seq = jrand48(sl->xsubi);
        txpos = dcs.pos = 0;

        /* Figure out how long we're going to be sending and receiving
         * data on the socket before closing it.
         */
        gettimeofday(&tnow, NULL);
        tend = tnow;
        do {
            f = erand48(sl->xsubi) * opint;
            tend.tv_sec += floor(f);
            f -= floor(f);
            f *= 1e+6;
            tend.tv_usec += floor(f) + 1;
            if (tend.tv_usec > 999999) {
                tend.tv_usec -= 1000000;
                tend.tv_sec += 1;
            }
        } while (nrand48(sl->xsubi) & 16);

        /* Send and receive data on the connected socket, until we
         * decide to do otherwise.
         */
        for (;;) {
            /* see if we're going to stop */
            gettimeofday(&tnow, NULL);
            if (tnow.tv_sec > tend.tv_sec ||
                (tnow.tv_sec == tend.tv_sec &&
                 tnow.tv_usec >= tend.tv_usec)) {

                /* done */
                break;
            }

            /* see if we've been called on to report status */
            if (status_ctl_mon != status_ctl) {
                status_ctl_mon = status_ctl;
                tmsg("%s: received %lld bytes, sent %lld bytes",
                     sname, (long long)received, (long long)sent);
            }

            /* receive data if we can */
            idle = 1;
            todo = sizeof(rbuf) - rgot;
            if (nrand48(sl->xsubi) & 16) {
                todo = 1 + (nrand48(sl->xsubi) % todo);
            }
            rv = read(csok, rbuf + rgot, todo);
            if (rv == 0 || (rv < 0 && errno == EPIPE)) {
                /* the other side closed the connection */
                tmsg("%s: apparently other side closed connection", sname);
                break;
            } else if (rv < 0) {
                if (errno == EINTR) {
                    /* transient and not really an error */
                    idle = 0;
                } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    /* can't read, at the moment */
                } else {
                    tmsg("%s: read() failed: %s", sname, strerror(errno));
                    break;
                }
            } else if (rv > 0) {
                /* validate the received data & consume it if we have enough */
                rgot += rv;
                received += rv;
                rgot = dpds_consume(sname, rbuf, rgot, &dcs);
                idle = 0;
            }

            /* generate data & send it if we can */
            while (wgot + DPDS_SIZE < sizeof(wbuf)) {
                dpds_encode(wbuf + wgot, txseq, txpos);
                txpos++;
                wgot += DPDS_SIZE;
            }
            todo = wgot;
            if (nrand48(sl->xsubi) & 16) {
                todo = 1 + (nrand48(sl->xsubi) % todo);
            }
            rv = write(csok, wbuf, todo);
            if (rv == 0) {
                /* write(2) suggests this can happen but doesn't say why */
                tmsg("%s: empty write(), treating as error", sname);
                break;
            } else if (rv < 0) {
                if (errno == EINTR) {
                    /* transient and not really an error */
                } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    /* can't write, at the moment */
                    if (idle) {
                        /* neither reading nor writing; pause to avoid
                         * eating excessive CPU
                         */
                        fsleep(0.1);
                    } else {
                        /* just go around again */
                    }
                } else {
                    tmsg("%s: write() failed: %s", sname, strerror(errno));
                    break;
                }
            } else {
                sent += rv;
                if (wgot > rv) {
                    memmove(wbuf, wbuf + rv, wgot - rv);
                }
                wgot -= rv;
            }
        }

        /* close the sockets & remove them */
        tmsg("Closing %s/%s", sockdir, sname);
        close(lsok);
        close(csok);
        snprintf(aun.sun_path, sizeof(aun.sun_path),
                 "%s/%s", sockdir, sname);
        unlink(aun.sun_path);
    }
}

/** ** ** main program ** ** **/

static void usage(void)
{
    fprintf(stderr, "see comments in source file for instructions\n");
    exit(1);
}

int main(int argc, char **argv)
{
    u_int32_t selftest_inputs[] = {
        1, 23,
        456, 78910,
        1000, 10000,
        1000, 10001,
        1001, 10001,
        1001, 10000,
        0
    };

    int i, j, ch;
    struct slot *slots;

    /* parse command line parameters */
    if (argc != 6) {
        usage();
    }
    sockdir = argv[1]; /* put sockets in this directory */
    nslots = 2 * atoi(argv[2]); /* number of socket "slots" */
    opint = atof(argv[3]); /* "typical" seconds between remove/add socket */
    listdel = atof(argv[4]); /* "typical" seconds between create/listen */
    accdel = atof(argv[5]); /* "typical" seconds before accept */
    
    /* self-test dpds_encode() / dpds_decode() */
    fprintf(stderr, "Self-testing dpds_encode() / dpds_decode()\n");
    for (i = 0; selftest_inputs[i]; i += 2) {
        u_int32_t seq, pos, seq2, pos2;
        u_int8_t stbuf[8];

        seq = selftest_inputs[i];
        pos = selftest_inputs[i+1];
        dpds_encode(stbuf, seq, pos);
        dpds_decode(&seq2, &pos2, stbuf);
        fprintf(stderr, "dpds_encode(0x%08lx, 0x%08lx) =",
                (unsigned long)seq, (unsigned long)pos);
        for (j = 0; j < 8; ++j) {
            fprintf(stderr, " %02x", (unsigned)stbuf[j]);
        }
        fprintf(stderr, "\ndpds_decode(...) = (0x%08lx, 0x%08lx)\n",
               (unsigned long)seq2, (unsigned long)pos2);
        if (seq != seq2 || pos != pos2) {
            fprintf(stderr, "MISMATCH!\n");
            exit(1);
        }
    }

    /* initialization */
    pthread_mutex_init(&tmsg_mutex, NULL);
    slots = calloc(nslots, sizeof(slots[0]));
    srand48(time(NULL)); /* not a secure practice; but it's just for a test */

    /* start threads, they'll run and do their thing */
    for (i = 0; i < nslots; ++i) {
        slots[i].i = i;
        slots[i].xsubi[0] = lrand48();
        slots[i].xsubi[1] = lrand48();
        slots[i].xsubi[2] = lrand48();
        pthread_create(&(slots[i].thread), NULL,
                       &slot_main, &(slots[i]));
    }

    /* and just wait, forever (rather, until control-C) */
    for (;;) {
        ch = fgetc(stdin);
        if (ch == 3) {
            /* this is not how we expect to get control-C, but hey */
            break;
        } else if (ch < 0) {
            /* no stdin, just wait forever */
            sleep(432000); /* 5 days */
        } else {
            /* newline (and whatever else): trigger a status report */
            ++status_ctl;
        }
    }
}

