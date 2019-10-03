/* sockptyr_core.c -- Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
 *
 * This is the C part of the "sockptyr" application.  See my notes for design.
 * To use:
 *      compile into a shared library
 *      load that into Tcl with "load $filename sockptyr"
 *      issue the various "sockptyr" commands to configure & manage it
 * The latter two steps are meant to be done by some Tcl code I'll
 * write later.
 */

#ifndef USE_INOTIFY
#define USE_INOTIFY 0
/* Compile with -DUSE_INOTIFY=1 on Linux to take advantage of inotify(7). */
/* XXX inotify code not much tested yet */
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <assert.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <tcl.h>
#if USE_INOTIFY
#include <sys/inotify.h>
#endif /* USE_INOTIFY */
#include <sys/socket.h>
#include <sys/un.h>

static const char *handle_prefix = "sockptyr_";

#if USE_INOTIFY
static struct {
    char *name;
    uint32_t value;
} inotify_bits[] = {
#define INOT_FLAG(x) { #x, x }
    /* (this current list based on Linux 4.19.2 kernel) */
    /* single bit flags for events you can request and receive */
    INOT_FLAG(IN_ACCESS),       /* File was accessed */
    INOT_FLAG(IN_MODIFY),       /* File was modified */
    INOT_FLAG(IN_ATTRIB),       /* Metadata changed */
    INOT_FLAG(IN_CLOSE_WRITE),  /* Writtable file was closed */
    INOT_FLAG(IN_CLOSE_NOWRITE),/* Unwrittable file closed */
    INOT_FLAG(IN_OPEN),         /* File was opened */
    INOT_FLAG(IN_MOVED_FROM),   /* File was moved from X */
    INOT_FLAG(IN_MOVED_TO),     /* File was moved to Y */
    INOT_FLAG(IN_CREATE),       /* Subfile was created */
    INOT_FLAG(IN_DELETE),       /* Subfile was deleted */
    INOT_FLAG(IN_DELETE_SELF),  /* Self was deleted */
    INOT_FLAG(IN_MOVE_SELF),    /* Self was moved */

    /* single bit flags for events you receive but don't request */
    INOT_FLAG(IN_UNMOUNT),      /* Backing fs was unmounted */
    INOT_FLAG(IN_Q_OVERFLOW),   /* Event queued overflowed */
    INOT_FLAG(IN_IGNORED),      /* File was ignored */

    /* not events; flags you set when watching */
    INOT_FLAG(IN_ONLYDIR),      /* only watch the path if it is a directory */
    INOT_FLAG(IN_DONT_FOLLOW),  /* don't follow a sym link */
    INOT_FLAG(IN_EXCL_UNLINK),  /* exclude events on unlinked objects */
#ifdef IN_MASK_CREATE
    INOT_FLAG(IN_MASK_CREATE),  /* only create watches */
#endif
    INOT_FLAG(IN_MASK_ADD),     /*add to the mask of an already existing watch*/
    INOT_FLAG(IN_ISDIR),        /* event occurred against dir */
    INOT_FLAG(IN_ONESHOT),      /* only send event once */

    /* names for groups of the flags above */
    INOT_FLAG(IN_CLOSE),        /* close */
    INOT_FLAG(IN_MOVE),         /* moves */

    /* mark the end of inotify flags */
    { NULL, 0 }
};

struct sockptyr_inot {
    /* inotify(7) watch specific information in sockptyr */
    int wd; /* watch descriptor used to identify its events */
    Tcl_Obj *proc; /* Tcl code to run when encountered */
};
#endif /* USE_INOTIFY */

struct sockptyr_conn {
    /* connection specific information in sockptyr */
    int fd; /* file descriptor; -1 if closed */
    /* buf* -- buffer for receiving data on this connection
     *      buf -- the buffer itself
     *      buf_sz -- size of the buffer in bytes
     *      buf_empty -- boolean indicating the buffer is empty
     *      buf_in -- index in buffer where next received data goes
     *      buf_out -- index in buffer where next used data comes from
     */
    unsigned char *buf;
    int buf_sz, buf_empty, buf_in, buf_out;

    /* two connections can be (& often are) "linked"; the entry 'linked'
     * points to the connection here
     */
    struct sockptyr_hdl *linked;

    char *onclose, *onerror; /* Tcl scripts to handle events */
};

struct sockptyr_lstn {
    /* listen() socket specific information in sockptyr */
    int sok; /* socket file descriptor */
    Tcl_Obj *proc; /* Tcl code to run for each new connection */
};

struct sockptyr_hdl {
    /* Info about a single handle in sockptyr. */
    struct sockptyr_data *sd; /* global data */
    int num; /* handle number */

    enum usage {
        usage_empty, /* just a placeholder, not counted, available for use */
        usage_dead, /* allocated but not usable */
        usage_conn, /* a connection, identifiable by handle */
#if USE_INOTIFY
        usage_inot, /* something monitored with "sockptyr inotify" */
#endif /* USE_INOTIFY */
        usage_exec, /* program started by "sockptyr exec" if I ever
                     * decide to implement it
                     */
        usage_lstn, /* a listen() socket created with "sockptyr listen" */
    } usage;

    union {
        /* information specific to particular 'usage' values */

        struct sockptyr_conn u_conn; /* if usage == usage_conn */
#if USE_INOTIFY
        struct sockptyr_inot u_inot; /* if usage == usage_inot */
#endif /* USE_INOTIFY */
        struct sockptyr_lstn u_lstn; /* if usage == usage_lstn */
    } u;

    /* 'next' & 'prev' put handles with particular 'usage' values into
     * a doubly linked list.  So far used only used for:
     *      usage_inot: list head is inotify_hdls in struct sockptyr_data
     *      usage_empty: list head is empty_hdls in struct sockptyr_data
     */
    struct sockptyr_hdl *next;
    struct sockptyr_hdl *prev;
};

struct sockptyr_data {
    /* state of the whole sockptyr instance on a given interpreter */

    Tcl_Interp *interp; /* interpreter for event handling etc */
    struct sockptyr_hdl *empty_hdls; /* handles with usage_empty */
    struct sockptyr_hdl **hdls; /* handles that have been created */
    int ahdls; /* count of entries in hdls[] */
#if USE_INOTIFY
    int inotify_fd; /* file descriptor for inotify(7) */
    struct sockptyr_hdl *inotify_hdls; /* handles with usage_inot */
#endif /* USE_INOTIFY */
};

static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd);
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls);
static void sockptyr_cleanup(ClientData cd);
static int sockptyr_cmd(ClientData cd, Tcl_Interp *interp,
                        int argc, const char *argv[]);
static int sockptyr_cmd_open_pty(ClientData cd, Tcl_Interp *interp,
                                 int argc, const char *argv[]);
static int sockptyr_cmd_connect(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[]);
static int sockptyr_cmd_listen(ClientData cd, Tcl_Interp *interp,
                               int argc, const char *argv[]);
static int sockptyr_cmd_link(ClientData cd, Tcl_Interp *interp,
                             int argc, const char *argv[]);
static int sockptyr_cmd_onclose(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[]);
static int sockptyr_cmd_onerror(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[]);
static int sockptyr_cmd_onclose_onerror(struct sockptyr_data *sd,
                                        Tcl_Interp *interp,
                                        int argc, const char *argv[],
                                        char *what, int isonerror);
static int sockptyr_cmd_dbg_handles(ClientData cd, Tcl_Interp *interp);
static void sockptyr_dbg_handles_one(Tcl_Interp *interp,
                                     struct sockptyr_hdl *hdl, int num,
                                     char *err, int errsz);
static void sockptyr_dbg_handles_lst(Tcl_Interp *interp,
                                     struct sockptyr_data *sd,
                                     struct sockptyr_hdl **hdls,
                                     enum usage usage, const char *lbl,
                                     char *err, int errsz);
static int sockptyr_cmd_info(ClientData cd, Tcl_Interp *interp,
                             int argc, const char *argv[]);
#if USE_INOTIFY
static int sockptyr_cmd_inotify(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[]);
#endif /* USE_INOTIFY */
static int sockptyr_cmd_close(ClientData cd, Tcl_Interp *interp,
                              int argc, const char *argv[]);
static void sockptyr_clobber_handle(struct sockptyr_hdl *hdl);
static void sockptyr_init_conn(struct sockptyr_hdl *hdl, int fd, int code);
static void sockptyr_close_conn(struct sockptyr_hdl *hdl);
static void sockptyr_register_conn_handler(struct sockptyr_hdl *hdl);
static void sockptyr_conn_handler(ClientData cd, int mask);
static void sockptyr_lstn_handler(ClientData cd, int mask);
static void sockptyr_conn_event(struct sockptyr_hdl *hdl,
                                char *errkw, char *errstr);
static void sockptyr_lst_insert(struct sockptyr_hdl **head,
                                struct sockptyr_hdl *hdl);
static void sockptyr_lst_remove(struct sockptyr_hdl **head,
                                struct sockptyr_hdl *hdl);
#if USE_INOTIFY
static void sockptyr_inot_handler(ClientData cd, int mask);
static Tcl_Obj *sockptyr_inot_flagrep(Tcl_Interp *interp, uint32_t flags);
#endif /* USE_INOTIFY */

/*
 * Sockptyr_Init() -- The only external interface of "sockptyr_core.c" this
 * is run when you do "load $filename sockptyr" in Tcl.  It in turn registers
 * our commands and sets things up and stuff.
 *
 * If "sockptyr" is loaded into more than one intepreter they can't see
 * each other's stuff or do anything together.
 */
int Sockptyr_Init(Tcl_Interp *interp)
{
    struct sockptyr_data *sd;

    sd = (void *)ckalloc(sizeof(*sd));
    memset(sd, 0, sizeof(*sd));
    sd->hdls = NULL;
    sd->ahdls = 0;
    sd->empty_hdls = NULL;
    sd->interp = interp;
#if USE_INOTIFY
    sd->inotify_fd = -1;
    sd->inotify_hdls = NULL;
#endif /* USE_INOTIFY */

    Tcl_CreateCommand(interp, "sockptyr",
                      &sockptyr_cmd, sd, &sockptyr_cleanup);
    return(TCL_OK);
}

/* sockptyr_cmd() -- handle the "sockptyr" command invoked in Tcl.
 */
static int sockptyr_cmd(ClientData cd, Tcl_Interp *interp,
                        int argc, const char *argv[])
{
    if (argc < 2) {
        Tcl_SetResult(interp,
                      "wrong # args: should be"
                      " \"sockptyr subcommand ?arg ...\"", TCL_STATIC);
        return(TCL_ERROR);
    } else if (!strcmp(argv[1], "open_pty")) {
        return(sockptyr_cmd_open_pty(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "connect")) {
        return(sockptyr_cmd_connect(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "listen")) {
        return(sockptyr_cmd_listen(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "link")) {
        return(sockptyr_cmd_link(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "onclose")) {
        return(sockptyr_cmd_onclose(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "onerror")) {
        return(sockptyr_cmd_onerror(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "info")) {
        return(sockptyr_cmd_info(cd, interp, argc - 2, argv + 2));
#if USE_INOTIFY
    } else if (!strcmp(argv[1], "inotify")) {
        return(sockptyr_cmd_inotify(cd, interp, argc - 2, argv + 2));
#endif /* USE_INOTIFY */
    } else if (!strcmp(argv[1], "close")) {
        return(sockptyr_cmd_close(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "dbg_handles")) {
        return(sockptyr_cmd_dbg_handles(cd, interp));
    } else {
        Tcl_SetResult(interp, "unknown subcommand", TCL_STATIC);
        return(TCL_ERROR);
    }
}

/* sockptyr_cleanup() -- free a 'struct sockptyr_data' and everything that goes
 * under it.
 */
static void sockptyr_cleanup(ClientData cd)
{
    struct sockptyr_data *sd = cd;
    int i;

    for (i = 0; i < sd->ahdls; ++i) {
        sockptyr_clobber_handle(sd->hdls[i]);
        ckfree((void *)sd->hdls[i]);
    }
    if (sd->hdls) {
        ckfree((void *)sd->hdls);
    }
    sd->hdls = NULL;
    sd->ahdls = 0;
#if USE_INOTIFY
    if (sd->inotify_fd >= 0) {
        Tcl_DeleteFileHandler(sd->inotify_fd);
        close(sd->inotify_fd);
    }
#endif /* USE_INOTIFY */
    ckfree((void *)sd);
}

/* Tcl command "sockptyr open_pty" -- Open a PTY and return a handle for it
 * and file pathname.
 */
static int sockptyr_cmd_open_pty(ClientData cd, Tcl_Interp *interp,
                                 int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdl;
    char rb[128];
    int fd;

    if (argc != 0) {    
        Tcl_SetResult(interp, "usage: sockptyr open_pty", TCL_STATIC);
        return(TCL_ERROR);
    }

    /* get a handle we can use for our result */
    hdl = sockptyr_allocate_handle(sd);

    /* and open the PTY and set it up for use */
    fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (fd < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr open_pty:"
                                       " posix_openpt() failed: %s",
                                       strerror(errno)));
        return(TCL_ERROR);
    }
    if (grantpt(fd) < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr open_pty:"
                                       " grantpt() failed: %s",
                                       strerror(errno)));
        close(fd);
        return(TCL_ERROR);
    }
    if (unlockpt(fd) < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr open_pty:"
                                       " unlockpt() failed: %s",
                                       strerror(errno)));
        close(fd);
        return(TCL_ERROR);
    }

    /* return a handle string that leads back to 'hdl'; and the PTY filename */
    sockptyr_init_conn(hdl, fd, 'p');
    snprintf(rb, sizeof(rb), "%s%d %s",
             handle_prefix, (int)hdl->num, ptsname(fd));
    Tcl_SetResult(interp, rb, TCL_VOLATILE);
    return(TCL_OK);
}

/* Tcl command "sockptyr connect" -- Connect to a unix domain stream socket
 * given by pathname.  Return handle for the connection.
 */
static int sockptyr_cmd_connect(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdl;
    struct sockaddr_un sa;
    char rb[128];
    int fd, l;

    if (argc != 1) {
        Tcl_SetResult(interp, "usage: sockptyr connect $path", TCL_STATIC);
        return(TCL_ERROR);
    }

    /* process the address we were given */
    memset(&sa, 0, sizeof(sa));
#if 0 /* some platforms have sun_len, some don't */
    sa.sun_len = sizeof(sa);
#endif
    sa.sun_family = AF_UNIX;
    l = strlen(argv[0]);
    if (l >= sizeof(sa.sun_path)) {
        Tcl_SetResult(interp, "sockptyr connect: path name too long",
                      TCL_STATIC);
        return(TCL_ERROR);
    }
    strcpy(&(sa.sun_path[0]), argv[0]);

    /* open a socket and connect */
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr connect:"
                                       " socket() failed: %s",
                                       strerror(errno)));
        return(TCL_ERROR);
    }
    if (connect(fd, (void *)&sa, sizeof(sa)) < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr connect:"
                                       " connect(%s) failed: %s",
                                       argv[0], strerror(errno)));
        close(fd);
        return(TCL_ERROR);
    }

    /* get a handle we can use for our result; return a string for it */
    hdl = sockptyr_allocate_handle(sd);
    sockptyr_init_conn(hdl, fd, 'c');
    snprintf(rb, sizeof(rb), "%s%d", handle_prefix, (int)hdl->num);
    Tcl_SetResult(interp, rb, TCL_VOLATILE);
    return(TCL_OK);
}

/* Tcl command "sockptyr listen" -- Open a unix domain stream socket
 * given by pathname & listen for connections on it.  Execute a Tcl
 * script for each new connection.
 *
 * Parameters:
 *      path: filename/address of the socket to listen on
 *      proc: Tcl script to execute after appending two words:
 *          a handle for the new connection
 *          empty string (reserved for peer address in the future)
 *
 * This creates the socket file, and fails if it already exists.
 */
static int sockptyr_cmd_listen(ClientData cd, Tcl_Interp *interp,
                               int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdl;
    struct sockptyr_lstn *lstn;
    struct sockaddr_un sa;
    int sok, l;

    if (argc != 2) {
        Tcl_SetResult(interp, "usage: sockptyr listen $path $proc", TCL_STATIC);
        return(TCL_ERROR);
    }

    /* process the address we were given */
    memset(&sa, 0, sizeof(sa));
#if 0 /* some platforms have sun_len, some don't */
    sa.sun_len = sizeof(sa);
#endif
    sa.sun_family = AF_UNIX;
    l = strlen(argv[0]);
    if (l >= sizeof(sa.sun_path)) {
        Tcl_SetResult(interp, "sockptyr connect: path name too long",
                      TCL_STATIC);
        return(TCL_ERROR);
    }
    strcpy(&(sa.sun_path[0]), argv[0]);

    /* open a socket and listen */
    sok = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sok < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr listen:"
                                       " socket() failed: %s",
                                       strerror(errno)));
        return(TCL_ERROR);
    }
    if (bind(sok, (void *)&sa, sizeof(sa)) < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr listen:"
                                       " bind(%s) failed: %s",
                                       argv[0], strerror(errno)));
        close(sok);
        return(TCL_ERROR);
    }
    if (listen(sok, 2) < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr listen:"
                                       " listen() failed: %s",
                                       strerror(errno)));
        close(sok);
        return(TCL_ERROR);
    }

    /* get a handle we can use for our result; return a string for it */
    hdl = sockptyr_allocate_handle(sd);
    hdl->usage = usage_lstn;
    lstn = &(hdl->u.u_lstn);
    memset(lstn, 0, sizeof(*lstn));
    lstn->sok = sok;
    lstn->proc = Tcl_NewStringObj(argv[1], strlen(argv[1]));
    Tcl_IncrRefCount(lstn->proc);
    Tcl_CreateFileHandler(lstn->sok, TCL_READABLE, &sockptyr_lstn_handler,
                          (ClientData)hdl);
    Tcl_SetObjResult(interp,
                     Tcl_ObjPrintf("%s%d", handle_prefix, (int)hdl->num));
    return(TCL_OK);
}

/* Tcl command "sockptyr link $hdl1 $hdl2" to link two connections together */
static int sockptyr_cmd_link(ClientData cd, Tcl_Interp *interp,
                             int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdls[2];
    struct sockptyr_conn *conns[2];
    int i;
    char buf[512];

    if (argc < 1 || argc > 2) {
        Tcl_SetResult(interp, "usage: sockptyr link $hdl1 ?$hdl2?", TCL_STATIC);
        return(TCL_ERROR);
    }

    /* find out what connections we're to operate on */
    for (i = 0; i < argc; ++i) {
        hdls[i] = sockptyr_lookup_handle(sd, argv[i]);
        if (hdls[i] == NULL || hdls[i]->usage != usage_conn) {
            snprintf(buf, sizeof(buf), "handle %s is not a connection handle",
                     argv[i]);
            Tcl_SetResult(interp, buf, TCL_VOLATILE);
            return(TCL_ERROR);
        }
        conns[i] = &(hdls[i]->u.u_conn);
    }

    /* unlink them from whatever they were on before */
    for (i = 0; i < argc; ++i) {
        if (conns[i]->linked) {
            conns[i]->linked->u.u_conn.linked = NULL;
            conns[i]->linked = NULL;
        }
    }

    if (argc > 1) {
        /* link them to each other */
        conns[0]->linked = hdls[1];
        conns[1]->linked = hdls[0];
    }

    /* and update what evens they can handle based on the new linkage */
    for (i = 0; i < argc; ++i) {
        sockptyr_register_conn_handler(hdls[i]);
    }

    return(TCL_OK);
}

/* Tcl "sockptyr onclose $hdl $proc": When $hdl is closed, invoke
 * Tcl script $proc.
 * Leave out $proc to cancel it.
 */
static int sockptyr_cmd_onclose(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    return(sockptyr_cmd_onclose_onerror(cd, interp, argc, argv,
                                        "onclose", 0));
}

/* Tcl "sockptyr onerror $hdl $proc": When an error occurs on $hdl
 * in the background, invoke Tcl script $proc with two list items appended
 * describing the exception:
 *      keyword loosely identifying the kind of error
 *      printable message like from strerror()
 * Leave out $proc to cancel it.
 */
static int sockptyr_cmd_onerror(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    return(sockptyr_cmd_onclose_onerror(cd, interp, argc, argv,
                                        "onerror", 1));
}

static int sockptyr_cmd_onclose_onerror(struct sockptyr_data *sd,
                                        Tcl_Interp *interp,
                                        int argc, const char *argv[],
                                        char *what, int isonerror)
{
    struct sockptyr_hdl *hdl;
    char **resp;

    if (sd->interp != interp) {
        /* shouldn't happen */
        Tcl_SetResult(interp, "cross interpreter call?!", TCL_STATIC);
        return(TCL_ERROR);
    }

    if (argc < 1 || argc > 2) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("usage: sockptyr %s $hdl ?$proc?",
                                       what));
        return(TCL_ERROR);
    }

    hdl = sockptyr_lookup_handle(sd, argv[0]);
    if (hdl == NULL || hdl->usage != usage_conn) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("handle %s is not a connection handle",
                                       argv[0]));
        return(TCL_ERROR);
    }

    resp = isonerror ? &(hdl->u.u_conn.onerror) : &(hdl->u.u_conn.onclose);
    if (*resp) {
        ckfree(*resp);
        *resp = NULL;
    }
    if (argc > 1) {
        *resp = ckalloc(strlen(argv[1]) + 1);
        strcpy(*resp, argv[1]);
    }

    return(TCL_OK);
}

/* sockptyr_allocate_handle() -- Find an unused handle or create it and
 * return a pointer to it.
 */
static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd)
{
    struct sockptyr_hdl *hdl;

    if (sd->empty_hdls == NULL) {
        /* we need some empty handles */
        int i = sd->ahdls;

        sd->ahdls += 1 + (sd->ahdls >> 2);
        sd->hdls = (void *)ckrealloc((void *)sd->hdls,
                                     sizeof(sd->hdls[0]) * sd->ahdls);
        for (; i < sd->ahdls; ++i) {
            hdl = sd->hdls[i] = (void *)ckalloc(sizeof(*hdl));
            memset(hdl, 0, sizeof(*hdl));
            hdl->sd = sd;
            hdl->num = i;
            hdl->usage = usage_empty;
            sockptyr_lst_insert(&(sd->empty_hdls), hdl);
        }
    }

    /* pick one of the empty handles in the doubly-linked-list of them */
    hdl = sd->empty_hdls;
    sockptyr_lst_remove(&(sd->empty_hdls), hdl);

    /* prepare it */
    hdl->next = hdl->prev = NULL;
    hdl->usage = usage_dead;

    return(hdl);
}

/* sockptyr_lookup_handle() -- look up the specified handle, and return
 * it, or NULL if not found or not allocated.
 */
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls)
{
    int hdln;
    struct sockptyr_hdl *hdl;

    if (!hdls) {
        return(NULL); /* no handle */
    }
    if (strncasecmp(hdls, handle_prefix, strlen(handle_prefix)) != 0) {
        return(NULL); /* not a handle */
    }
    hdln = atoi(hdls + strlen(handle_prefix));
    if (hdln < 0) {
        return(NULL); /* not a handle */
    }
    if (hdln >= sd->ahdls) {
        return(NULL); /* this handle number has never been allocated */
    }

    hdl = sd->hdls[hdln];

    if (hdl->usage == usage_empty) {
        return(NULL); /* handle not allocated */
    }
    return(hdl);
}

/* sockptyr_clobber_handle() -- Clean up handle 'hdl'.
 * This could, sometimes, free the sockptyr_hdl,
 * but doesn't; simpler to leave it around unused until/unless we want
 * it again.
 */
static void sockptyr_clobber_handle(struct sockptyr_hdl *hdl)
{
    if (!hdl) return; /* nothing to do */

    switch (hdl->usage) {
    case usage_empty:
        /* nothing to do at all */
        return;
    case usage_dead:
        /* nothing more to do */
        break;
    case usage_conn:
        {
            struct sockptyr_conn *conn = &(hdl->u.u_conn);
            if (conn) {
                if (conn->fd >= 0) {
                    Tcl_DeleteFileHandler(conn->fd);
                    close(conn->fd);
                }
                if (conn->linked) {
                    conn->linked->u.u_conn.linked = NULL;
                }
                ckfree((void *)conn->buf);
                if (conn->onclose) ckfree(conn->onclose);
                if (conn->onerror) ckfree(conn->onerror);
            }
        }
        break;
#if USE_INOTIFY
    case usage_inot:
        {
            struct sockptyr_inot *inot = &(hdl->u.u_inot);
            if (inot) {
                inotify_rm_watch(hdl->sd->inotify_fd, inot->wd);
                sockptyr_lst_remove(&(hdl->sd->inotify_hdls), hdl);
                Tcl_DecrRefCount(inot->proc);
            }
        }
        break;
#endif /* USE_INOTIFY */
    case usage_lstn:
        {
            struct sockptyr_lstn *lstn = &(hdl->u.u_lstn);
            if (lstn) {
                if (lstn->sok >= 0) {
                    Tcl_DeleteFileHandler(lstn->sok);
                    close(lstn->sok);
                }
                Tcl_DecrRefCount(lstn->proc);
            }
        }
        break;
    default:
        /* shouldn't happen */
        --*(unsigned *)1; /* this is intended to crash */
        break;
    }

    hdl->usage = usage_empty;
    sockptyr_lst_insert(&(hdl->sd->empty_hdls), hdl);
    memset(&(hdl->u), 0, sizeof(hdl->u));
}

/* sockptyr_init_conn(): Initialize a sockptyr handle structure for
 * tracking a connection.  'fd' is the file descriptor for that connection
 * (often, a socket).  'code' is a code indicating the type of connection:
 *      'p' - PTY
 */
static void sockptyr_init_conn(struct sockptyr_hdl *hdl, int fd, int code)
{
    struct sockptyr_conn *conn;

    hdl->usage = usage_conn;
    conn = &(hdl->u.u_conn);
    memset(conn, 0, sizeof(*conn));
    conn->fd = fd;
    conn->buf_sz = 4096;
    conn->buf = (void *)ckalloc(conn->buf_sz);
    conn->buf_empty = 1;
    conn->buf_in = conn->buf_out = 0;
    conn->linked = NULL;
    conn->onclose = conn->onerror = NULL;
    sockptyr_register_conn_handler(hdl);
}

/* Tcl command "sockptyr dbg_handles" -- returns a list (of name value
 * pairs like in setting an array) about the allocation of handles; giving
 * things like type and links and how they fit together.  For debugging
 * in case the name didn't make that clear.
 */
static int sockptyr_cmd_dbg_handles(ClientData cd, Tcl_Interp *interp)
{
    char err[512];
    struct sockptyr_data *sd = cd;
    int i;

    Tcl_SetResult(interp, "", TCL_STATIC);
    err[0] = '\0';
    for (i = 0; i < sd->ahdls; ++i) {
        sockptyr_dbg_handles_one(interp, sd->hdls[i], i, err, sizeof(err));
    }
    
    sockptyr_dbg_handles_lst(interp, sd,
                             &(sd->empty_hdls), usage_empty, "empty",
                             err, sizeof(err));
#if USE_INOTIFY
    sockptyr_dbg_handles_lst(interp, sd,
                             &(sd->inotify_hdls), usage_inot, "inot",
                             err, sizeof(err));
#endif

    if (err[0]) {
        Tcl_AppendElement(interp, "err");
        Tcl_AppendElement(interp, err);
    }

    return(TCL_OK);
}

/* sockptyr_dbg_handles_one() -- Do one handle's part of
 * sockptyr_cmd_dbg_handles().
 */
static void sockptyr_dbg_handles_one(Tcl_Interp *interp,
                                     struct sockptyr_hdl *hdl, int num,
                                     char *err, int errsz)
{
    char buf[512];

    if (hdl == NULL) return; /* nothing to do */

    if (hdl->num != num && !err[0]) {
        snprintf(err, errsz, "num wrong, got %d exp %d",
                 (int)hdl->num, (int)num);
    }

    snprintf(buf, sizeof(buf), "%d usage", (int)hdl->num);
    Tcl_AppendElement(interp, buf);
    switch (hdl->usage) {
    case usage_empty:   Tcl_AppendElement(interp, "empty"); break;
    case usage_dead:    Tcl_AppendElement(interp, "dead"); break;
    case usage_conn:    Tcl_AppendElement(interp, "conn"); break;
#if USE_INOTIFY
    case usage_inot:    Tcl_AppendElement(interp, "inot"); break;
#endif
    case usage_exec:    Tcl_AppendElement(interp, "exec"); break;
    case usage_lstn:    Tcl_AppendElement(interp, "lstn"); break;
    default:
        if (!err[0]) {
            snprintf(err, errsz, "unknown usage value %d", (int)hdl->usage);
        }
        snprintf(buf, sizeof(buf), "%d", (int)hdl->usage);
        Tcl_AppendElement(interp, buf);
        break;
    }

    switch (hdl->usage) {
    case usage_empty:
        /* nothing very interesting to do */
        break;
    case usage_dead:
        /* nothing to do */
        break;
    case usage_conn:
        /* connection-specific stuff */
        {
            struct sockptyr_conn *conn = &(hdl->u.u_conn);
            snprintf(buf, sizeof(buf), "%d fd", (int)hdl->num);
            Tcl_AppendElement(interp, buf);
            snprintf(buf, sizeof(buf), "%d", (int)conn->fd);
            Tcl_AppendElement(interp, buf);
            snprintf(buf, sizeof(buf), "%d buf", (int)hdl->num);
            Tcl_AppendElement(interp, buf);
            snprintf(buf, sizeof(buf), "sz %d e %d i %d o %d",
                     (int)conn->buf_sz, (int)conn->buf_empty,
                     (int)conn->buf_in, (int)conn->buf_out);
            Tcl_AppendElement(interp, buf);
            if (conn->linked) {
                snprintf(buf, sizeof(buf), "%d linked", (int)hdl->num);
                Tcl_AppendElement(interp, buf);
                snprintf(buf, sizeof(buf), "%d", (int)conn->linked->num);
                Tcl_AppendElement(interp, buf);
                if (conn->linked->usage != usage_conn && !err[0]) {
                    snprintf(err, errsz, "on %d link to wrong type",
                             (int)hdl->num);
                }
                else if (conn->linked->u.u_conn.linked != hdl && !err[0]) {
                    snprintf(err, errsz, "%d links to %d links to %d",
                             (int)hdl->num,
                             (int)conn->linked->num,
                             (int)(conn->linked->u.u_conn.linked ?
                                   conn->linked->u.u_conn.linked->num : -1));
                }
            }
            if (conn->onclose) {
                snprintf(buf, sizeof(buf), "%d onclose", (int)hdl->num);
                Tcl_AppendElement(interp, buf);
                Tcl_AppendElement(interp, conn->onclose);
            }
            if (conn->onerror) {
                snprintf(buf, sizeof(buf), "%d onerror", (int)hdl->num);
                Tcl_AppendElement(interp, buf);
                Tcl_AppendElement(interp, conn->onerror);
            }
        }
        break;
#if USE_INOTIFY
    case usage_inot:
        snprintf(buf, sizeof(buf), "%d wd", (int)hdl->num);
        Tcl_AppendElement(interp, buf);
        snprintf(buf, sizeof(buf), "%d", (int)hdl->u.u_inot.wd);
        Tcl_AppendElement(interp, buf);
        snprintf(buf, sizeof(buf), "%d proc", (int)hdl->num);
        Tcl_AppendElement(interp, buf);
        Tcl_AppendElement(interp, Tcl_GetString(hdl->u.u_inot.proc));
        break;
#endif /* USE_INOTIFY */
    case usage_exec:
        /* nothing to do (yet?) */
        break;
    case usage_lstn:
        snprintf(buf, sizeof(buf), "%d sok", (int)hdl->num);
        Tcl_AppendElement(interp, buf);
        snprintf(buf, sizeof(buf), "%d", (int)hdl->u.u_lstn.sok);
        Tcl_AppendElement(interp, buf);
        snprintf(buf, sizeof(buf), "%d proc", (int)hdl->num);
        Tcl_AppendElement(interp, buf);
        Tcl_AppendElement(interp, Tcl_GetString(hdl->u.u_lstn.proc));
        break;
    }
}

/* sockptyr_dbg_handles_one() -- Check one of the doubly linked lists
 * of handles of a particular usage type, as part of sockptyr_cmd_dbg_handles().
 */
static void sockptyr_dbg_handles_lst(Tcl_Interp *interp,
                                     struct sockptyr_data *sd,
                                     struct sockptyr_hdl **hdls,
                                     enum usage usage, const char *lbl,
                                     char *err, int errsz)
{
    int lcnt, acnt, i;
    struct sockptyr_hdl *thumb;

    if (err[0]) {
        /* if there's already an error reported don't check any more */
        return;
    }

    /* Go through the list checking that it contains handles that are
     * right and that it's linked properly.  Also count the handles.
     */
    for (lcnt = 0, thumb = *hdls; thumb; thumb = thumb->next) {
        ++lcnt;
        if (thumb->prev && thumb->prev->next != thumb) {
            snprintf(err, errsz,
                     "bad linkage: %d->prev = %d, %d->next = %d != %d",
                     (int)thumb->num, (int)thumb->prev->num,
                     (int)thumb->prev->num, (int)thumb->prev->next->num,
                     (int)thumb->num);
            return;
        }
        if (thumb->prev == NULL && thumb != *hdls) {
            snprintf(err, errsz,
                     "bad linkage: %d->prev = null but %d is first in list",
                     (int)thumb->num, (int)(*hdls)->num);
            return;
        }
        if (thumb->next && thumb->next->prev != thumb) {
            snprintf(err, errsz,
                     "bad linkage: %d->next = %d, %d->prev = %d != %d",
                     (int)thumb->num, (int)thumb->next->num,
                     (int)thumb->next->num, (int)thumb->next->prev->num,
                     (int)thumb->num);
            return;
        }
        if (thumb->usage != usage) {
            snprintf(err, errsz,
                     "handle %d has wrong usage type exp %d got %d in"
                     " the %s list",
                     (int)thumb->num, (int)usage,
                     (int)thumb->usage, lbl);
            return;
        }
    }

    /* And go through the array of handles to count the number of handles
     * with this usage type
     */
    for (i = acnt = 0; i < sd->ahdls; ++i) {
        if (sd->hdls[i]->usage == usage) {
            ++acnt;
        }
    }
    if (lcnt != acnt) {
        snprintf(err, errsz,
                 "the %s list has %d handles out of the %d with that"
                 " type -- some are missing",
                 lbl, (int)lcnt, (int)acnt);
        return;
    }
}

/* Tcl command "sockptyr info" -- Provide some compile time information
 * about this software, in the form of name value pairs like you'd use
 * to initialize an array.
 */
static int sockptyr_cmd_info(ClientData cd, Tcl_Interp *interp,
                             int argc, const char *argv[])
{
    char buf[512];

    if (argc != 0) {    
        Tcl_SetResult(interp, "usage: sockptyr info", TCL_STATIC);
        return(TCL_ERROR);
    }

    Tcl_SetResult(interp, "", TCL_STATIC);

    Tcl_AppendElement(interp, "USE_INOTIFY");
    snprintf(buf, sizeof(buf), "%d", (int)USE_INOTIFY);
    Tcl_AppendElement(interp, buf);

    return(TCL_OK);
}

#if USE_INOTIFY
/* Tcl command "sockptyr inotify" -- Interface to Linux's inotify(7)
 * subsystem. The first call to "sockptyr inotify" creates a notify
 * instance; each call adds a watch to it.
 *
 * Parameters:
 *      filename
 *      list of events to watch for (along with a few additional flags
 *          inotify_add_watch() takes); example: {IN_ACCESS IN_ATTRIB}
 *      Tcl script to run when even occurs; with the following appended:
 *          list of event flags like IN_ACCESS
 *          cookie associating related events
 *          name field if any, or empty string
 *
 * This implementation is inefficient for having a lot of watches; doesn't
 * provide all the conceivable options; is only available on Linux.
 */
static int sockptyr_cmd_inotify(ClientData cd, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdl;
    struct sockptyr_inot *inot;
    uint32_t mask;
    int mask_argc, i, j, wd;
    const char **mask_argv;
    char *ep;

    if (argc != 3) {
        Tcl_SetResult(interp, "usage: sockptyr inotify $path $mask $run",
                      TCL_STATIC);
        return(TCL_ERROR);
    }

    /* create an inotify instance if we haven't already */
    if (sd->inotify_fd < 0) {
        sd->inotify_fd = inotify_init();
        if (sd->inotify_fd < 0) {
            Tcl_SetObjResult(interp,
                             Tcl_ObjPrintf("inotify_init() failed: %s",
                                           strerror(errno)));
            return(TCL_ERROR);
        }
        Tcl_CreateFileHandler(sd->inotify_fd, TCL_READABLE,
                              &sockptyr_inot_handler, (ClientData)sd);
    }

    /* process the mask value */
    mask = 0;
    mask_argc = 0;
    mask_argv = NULL;
    if (Tcl_SplitList(interp, argv[1], &mask_argc, &mask_argv) != TCL_OK) {
        return(TCL_ERROR);
    }
    for (i = 0; i < mask_argc; ++i) {
        for (j = 0; inotify_bits[j].name; ++j) {
            if (!strcasecmp(mask_argv[i], inotify_bits[j].name)) {
                break;
            }
        }
        if (inotify_bits[j].name) {
            mask |= inotify_bits[j].value;
        } else {
            ep = NULL;
            mask |= strtol(mask_argv[i], &ep, 0);
            if (ep && *ep) {
                Tcl_SetObjResult(interp,
                                 Tcl_ObjPrintf("sockptyr inotify:"
                                               " unrecognized mask code '%s'",
                                               mask_argv[i]));
                Tcl_Free((void *)mask_argv);
                return(TCL_ERROR);
            }
        }
    }
    Tcl_Free((void *)mask_argv);

    /* set up the watch */
    wd = inotify_add_watch(sd->inotify_fd, argv[0], mask);
    if (wd < 0) {
        Tcl_SetObjResult(interp,
                         Tcl_ObjPrintf("sockptyr inotify:"
                                       " OS failed to add watch: %s",
                                       strerror(errno)));
        return(TCL_ERROR);
    }

    /* set up a handle we can use for our result; and fill it in */
    hdl = sockptyr_allocate_handle(sd);
    hdl->usage = usage_inot;
    inot = &(hdl->u.u_inot);
    memset(inot, 0, sizeof(*inot));
    inot->wd = wd;
    inot->proc = Tcl_NewStringObj(argv[2], strlen(argv[2]));
    Tcl_IncrRefCount(inot->proc);
    sockptyr_lst_insert(&(sd->inotify_hdls), hdl);

    /* return a handle string identifying it */
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s%d",
                                           handle_prefix, (int)hdl->num));
    return(TCL_OK);
}
#endif /* !USE_INOTIFY */

/* Tcl command "sockptyr close" -- Close (delete) something in sockptyr.
 * Can be called on the handle you get from any of the following:
 *      sockptyr open_pty
 *      sockptyr connect
 *      sockptyr inotify
 *      sockptyr listen
 * If this gets called on an already closed handle, nothing happens.
 */
static int sockptyr_cmd_close(ClientData cd, Tcl_Interp *interp,
                              int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *hdl;

    if (argc != 1) {
        Tcl_SetResult(interp, "usage: sockptyr close $hdl", TCL_STATIC);
        return(TCL_ERROR);
    }

    hdl = sockptyr_lookup_handle(sd, argv[0]);
    if (hdl == NULL) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("handle %s is not a handle",
                                               argv[0]));
        return(TCL_ERROR);
    }

    switch (hdl->usage) {
    case usage_empty:
        /* nothing to do */
        break;
    case usage_dead:
        sockptyr_clobber_handle(hdl);
        break;
    case usage_conn:
        sockptyr_close_conn(hdl);
        break;
#if USE_INOTIFY
    case usage_inot:
        sockptyr_clobber_handle(hdl);
        break;
#endif /* USE_INOTIFY */
    case usage_exec:
        sockptyr_clobber_handle(hdl);
        break;
    case usage_lstn:
        sockptyr_clobber_handle(hdl);
        break;
    }

    return(TCL_OK);
}

/* sockptyr_register_conn_handler(): For the given handle (which is
 * assumed to refer to a connection) set/clear file event handlers as
 * appropriate to handle the events that this connection is able to
 * deal with at the moment.
 */
static void sockptyr_register_conn_handler(struct sockptyr_hdl *hdl)
{
    int mask = 0;
    struct sockptyr_conn *conn = &(hdl->u.u_conn);

    if (conn->fd < 0) {
        /* nothing to do */
        return;
    }

    if (conn->buf_empty || conn->buf_in != conn->buf_out) {
        /* buffer isn't full; we can receive into it */
        mask |= TCL_READABLE;
    }
    if (conn->linked && !conn->linked->u.u_conn.buf_empty) {
        /* linked connection's buffer isn't empty; we can send from it */
        mask |= TCL_WRITABLE;
    }
#if 0
    fprintf(stderr, "sockptyr_register_conn_handler(): on %d mask %d\n",
            (int)hdl->num, (int)mask);
#endif
    Tcl_CreateFileHandler(conn->fd, mask, &sockptyr_conn_handler,
                          (ClientData)hdl);
}

/* sockptyr_conn_handler(): Called by the Tcl event loop when the file
 * descriptor associated with one of our connections can do something
 * we want to do.  'cd' contains the 'struct sockptyr_hdl *' associated
 * with the connection.
 */
static void sockptyr_conn_handler(ClientData cd, int mask)
{
    struct sockptyr_hdl *hdl = cd;
    struct sockptyr_conn *conn, *lconn;
    int rv, len;

    /* Sanity checks */
    assert(hdl != NULL);
    assert(hdl->usage == usage_conn);
    conn = &(hdl->u.u_conn);

#if 0
    fprintf(stderr, "sockptyr_conn_handler() on %d mask %d\n",
            (int)hdl->num, (int)mask);
#endif
    if (conn->fd < 0) {
        sockptyr_conn_event(hdl, "bug", "event on closed file descriptor");
    }

    /* see about receiving on this connection, into its buffer */
    if ((mask & TCL_READABLE) && (conn->buf_empty ||
                                  conn->buf_in != conn->buf_out)) {
        if (conn->buf_empty) {
            len = conn->buf_sz;
            conn->buf_in = conn->buf_out = 0;
        } else if (conn->buf_out > conn->buf_in) {
            len = conn->buf_out - conn->buf_in;
        } else {
            len = conn->buf_sz - conn->buf_in;
        }
        rv = read(conn->fd, conn->buf + conn->buf_in, len);
#if 0
        {
            int e = errno;
            fprintf(stderr, "read(): on %d, len %d rv %d errno %d\n",
                    (int)hdl->num, (int)len, (int)rv, (int)e);
            errno = e;
        }
#endif
        if (rv < 0) {
            if (errno == EINTR) {
                /* not really an error, just let it slide */
            } else {
                sockptyr_conn_event(hdl,
                                    (errno == EAGAIN || errno == EWOULDBLOCK) ?
                                    "bug" : /* got these on blocking socket? */
                                    "io", strerror(errno));
            }
        } else if (rv == 0) {
            /* connection closed */
            sockptyr_close_conn(hdl);
            return;
        } else {
            /* got something, record it in the buffer */
            conn->buf_empty = 0;
            conn->buf_in += rv;
        }
        if (conn->buf_in == conn->buf_sz) {
            /* wrap around */
            conn->buf_in = 0;
        }
    }

    /* see about sending on this connection, from the linked connection's
     * buffer
     */
    if ((mask & TCL_WRITABLE) && conn->linked &&
        !conn->linked->u.u_conn.buf_empty) {

        lconn = &(conn->linked->u.u_conn);
        if (lconn->buf_in > conn->buf_out) {
            len = lconn->buf_in - lconn->buf_out;
        } else {
            len = lconn->buf_sz - lconn->buf_out;
        }
        rv = write(conn->fd, lconn->buf + lconn->buf_out, len);
#if 0
        {
            int e = errno;
            fprintf(stderr, "write(): on %d, len %d rv %d errno %d\n",
                    (int)hdl->num, (int)len, (int)rv, (int)e);
            errno = e;
        }
#endif
        if (rv < 0) {
            /* EAGAIN / EWOULDBLOCK shouldn't happen on a blocking socket */
            if (errno == EINTR) {
                /* not really an error, just let it slide */
            } else {
                sockptyr_conn_event(hdl,
                                    (errno == EAGAIN || errno == EWOULDBLOCK) ?
                                    "bug" : /* got these on blocking socket? */
                                    "io", strerror(errno));
            }
        } else if (rv == 0) {
            /* shouldn't have happened */
            sockptyr_conn_event(hdl, "bug", "zero length write");
        } else {
            lconn->buf_out += rv;
            if (lconn->buf_out == lconn->buf_sz) {
                lconn->buf_out = 0; /* wrap around */
            }
            if (lconn->buf_in == lconn->buf_out || !lconn->linked) {
                /* became empty */
                lconn->buf_empty = 1;
                lconn->buf_in = lconn->buf_out = 0;
            }
        }
    }

    /* since buffer pointers may have moved, maybe the set of events we could
     * handle has changed
     */
    sockptyr_register_conn_handler(hdl);
    if (conn->linked)
        sockptyr_register_conn_handler(conn->linked);
}

#if USE_INOTIFY
/* sockptyr_inot_handler() -- When an inotify(7) message comes in,
 * read it, find the handler that was registered for it, and run
 * it.
 */
static void sockptyr_inot_handler(ClientData cd, int mask)
{
    struct sockptyr_data *sd = cd;
    struct inotify_event *ie;
    struct sockptyr_hdl *hdl;
    struct sockptyr_inot *inot;
    char buf[65536];
    int got, pos, rv;
    Tcl_Obj *tclcom, *flags;
    Tcl_Interp *interp = sd->interp;

    /* sanity checks */
    assert(mask & TCL_READABLE);
    assert(sd);
    assert(sd->inotify_fd >= 0);

    /* read some events into buf[] */
    got = read(sd->inotify_fd, buf, sizeof(buf));
    if (got < 0) {
        /* some kind of error happened */
        if (errno == EINTR) {
            /* not really an error, just let it slide */
        } else {
            /* really an error, but not much we can do right here! */
            fprintf(stderr, "sockptyr_inot_handler() read() error: %s\n",
                    strerror(errno));
            fprintf(stderr, "sockptyr inotify shutting down\n");
            Tcl_DeleteFileHandler(sd->inotify_fd);
            sd->inotify_fd = -1;
            return;
        }
    } else if (got == 0) {
        /* End of file shouldn't happen, and we shouldn't have been
         * called if there was nothing to read.  Don't let that happen
         * frequently.
         */
        fprintf(stderr, "sockptyr_inot_handler() read empty\n");
        fprintf(stderr, "sockptyr inotify shutting down\n");
        Tcl_DeleteFileHandler(sd->inotify_fd);
        sd->inotify_fd = -1;
        return;
    }

    for (pos = 0; pos < got; ) {
        ie = (void *)&(buf[pos]);
        if (got - pos < sizeof(*ie) ||
            got - pos < sizeof(*ie) + ie->len) {
            /* Not enough left in the buffer to make a whole event.
             * This shouldn't have happened:  I *think* the kernel shouldn't
             * do this.
             */
            fprintf(stderr, "sockptyr_inot_handler() read incomplete\n");
            fprintf(stderr, "sockptyr inotify shutting down\n");
            Tcl_DeleteFileHandler(sd->inotify_fd);
            sd->inotify_fd = -1;
            return;
        }

        /* Find our own watch information about ie->wd */
        for (hdl = sd->inotify_hdls; hdl; hdl = hdl->next) {
            if (ie->wd == hdl->u.u_inot.wd)
                break;
        }
        if (!hdl) {
            fprintf(stderr, "sockptyr_inot_handler() unknown wd %d; ignoring\n",
                    (int)ie->wd);
            inotify_rm_watch(sd->inotify_fd, ie->wd);
            sd->inotify_fd = -1;
            pos += sizeof(*ie) + ie->len;
            continue;
        }
        inot = &(hdl->u.u_inot);

        /* append additional info to inot->proc and call it */
        tclcom = Tcl_DuplicateObj(inot->proc);
        Tcl_IncrRefCount(tclcom);
        flags = sockptyr_inot_flagrep(interp, ie->mask);
        Tcl_ListObjAppendElement(interp, tclcom, flags);
        Tcl_DecrRefCount(flags);
        Tcl_ListObjAppendElement(interp, tclcom,
                                 Tcl_ObjPrintf("%lu",
                                               (unsigned long)ie->cookie));
        Tcl_ListObjAppendElement(interp, tclcom,
                                 Tcl_NewStringObj(ie->name,
                                                  strnlen(ie->name, ie->len)));
        Tcl_Preserve(interp);
        rv = Tcl_EvalObjEx(interp, tclcom, TCL_EVAL_GLOBAL);
#if 0 /* is Tcl_BackgroundException() maybe new? */
        if (result != TCL_OK) {
            Tcl_BackgroundException(interp, result);
        }
#endif
        Tcl_Release(interp);
        Tcl_DecrRefCount(tclcom);

        /* move on to the next one, if any */
        pos += sizeof(*ie) + ie->len;
    }
}
#endif /* USE_INOTIFY */

/* sockptyr_lstn_handler(): Called by the Tcl event loop when a socket
 * we've listen()ed on receives a connection.  'cd' contains the
 * 'struct sockptyr_hdl *' associated with that socket.
 *
 * Accepts the connection, sets up a sockptyr_hdl for it, and runs
 * some code with the handle.
 */
static void sockptyr_lstn_handler(ClientData cd, int mask)
{
    struct sockptyr_hdl *hdl = cd, *chdl;
    struct sockptyr_data *sd = hdl->sd;
    Tcl_Interp *interp = sd->interp;
    struct sockptyr_lstn *lstn;
    int rv, fd;
    struct sockaddr_un a;
    socklen_t l;
    Tcl_Obj *tclcom;

    /* Sanity checks */
    assert(hdl != NULL);
    assert(hdl->usage == usage_lstn);
    lstn = &(hdl->u.u_lstn);
    assert(lstn->sok >= 0);
    assert(mask & TCL_READABLE);

    /* Accept the connection */
    memset(&a, 0, sizeof(a));
    l = sizeof(a);
    fd = accept(lstn->sok, (void *)&a, &l);
    if (fd < 0) {
        if (errno == EINTR) {
            /* transient something or other, not an error; ignore */
            return;
        } else {
            /* some kind of error */
            fprintf(stderr, "accept(): on %d, failed: %s\n",
                    (int)lstn->sok, strerror(errno));
            sockptyr_clobber_handle(hdl);
            return;
        }
    }

    /* Set up a connection handle for it */
    chdl = sockptyr_allocate_handle(sd);
    sockptyr_init_conn(chdl, fd, 'a');

    /* Execute the Tcl handler proc */
    tclcom = Tcl_DuplicateObj(lstn->proc);
    Tcl_IncrRefCount(tclcom);
    Tcl_ListObjAppendElement(interp, tclcom,
                             Tcl_ObjPrintf("%s%d",
                                           handle_prefix, (int)chdl->num));
    Tcl_ListObjAppendElement(interp, tclcom, Tcl_NewObj());
    Tcl_Preserve(interp);
    rv = Tcl_EvalObjEx(interp, tclcom, TCL_EVAL_GLOBAL);
#if 0 /* is Tcl_BackgroundException() maybe new? */
        if (result != TCL_OK) {
            Tcl_BackgroundException(interp, result);
        }
#endif
    Tcl_Release(interp);
    Tcl_DecrRefCount(tclcom);
}

/* sockptyr_conn_event() -- handle something happening on a connection,
 * like an error or it being closed, by calling the registered Tcl handler.
 * If it's just closure, 'errkw' and 'errstr' should be NULL.  If it's
 * an error they should be filled in.
 *
 * 'hdl' is assumed to be a connection, not one of the other things.
 */
static void sockptyr_conn_event(struct sockptyr_hdl *hdl,
                                char *errkw, char *errstr)
{
    struct sockptyr_conn *conn = &(hdl->u.u_conn);
    struct sockptyr_data *sd = hdl->sd;
    Tcl_Interp *interp = sd->interp;
    Tcl_Obj *cmd;
    int result;

    if (errkw == NULL) {
        if (conn->onclose == NULL) return; /* no handler */

        cmd = Tcl_NewStringObj(conn->onclose, strlen(conn->onclose));
        Tcl_IncrRefCount(cmd);
    } else {
        if (conn->onerror == NULL) return; /* no handler */

        cmd = Tcl_NewStringObj(conn->onerror, strlen(conn->onerror));
        if (errkw == NULL) errkw = "";
        if (errstr == NULL) errstr = "";
        Tcl_ListObjAppendElement(interp, cmd,
                                 Tcl_NewStringObj(errkw, strlen(errkw)));
        Tcl_ListObjAppendElement(interp, cmd,
                                 Tcl_NewStringObj(errstr, strlen(errstr)));
        Tcl_IncrRefCount(cmd);
    }

    Tcl_Preserve(interp);
    result = Tcl_EvalObjEx(interp, cmd, TCL_EVAL_GLOBAL);
#if 0 /* is Tcl_BackgroundException() maybe new? */
    if (result != TCL_OK) {
        Tcl_BackgroundException(interp, result);
    }
#endif
    Tcl_Release(interp);
    Tcl_DecrRefCount(cmd);
}

/* sockptyr_close_conn(): Close a conection, given by handle.  The handle
 * must really be a connection or this will be bad.
 */
static void sockptyr_close_conn(struct sockptyr_hdl *hdl)
{
    sockptyr_conn_event(hdl, NULL, NULL);
    sockptyr_clobber_handle(hdl);
}

#if USE_INOTIFY
/* sockptyr_inot_flagrep(): Given a collection of inotify(7) flags, return
 * a list of names for them, derived from inotify_bits[].  The returned
 * Tcl object has a refcount of 1.
 */
static Tcl_Obj *sockptyr_inot_flagrep(Tcl_Interp *interp, uint32_t flags)
{
    Tcl_Obj *o;
    int i;
    uint32_t rep = 0;
    char *n;

    /* start with an empty list */
    o = Tcl_NewListObj(0, &o);
    Tcl_IncrRefCount(o);
    
    for (i = 0; inotify_bits[i].name; ++i) {
        if ((inotify_bits[i].value & flags) == inotify_bits[i].value) {
            rep |= inotify_bits[i].value;
            n = inotify_bits[i].name;
            Tcl_ListObjAppendElement(interp, o,
                                     Tcl_NewStringObj(n, strlen(n)));
        }
    }
    if (rep != flags) {
        rep = flags & ~rep;
        Tcl_ListObjAppendElement(interp, o,
                                 Tcl_ObjPrintf("%lu", (unsigned long)rep));
    }

    return(o);
}
#endif /* USE_INOTIFY */

/* sockptyr_lst_insert() -- Insert a handle into a doubly linked list. */
static void sockptyr_lst_insert(struct sockptyr_hdl **head,
                                struct sockptyr_hdl *hdl)
{
    hdl->prev = NULL;
    hdl->next = *head;
    if (hdl->next) {
        hdl->next->prev = hdl;
    }
    *head = hdl;
}

/* sockptyr_lst_remove() -- Remove a handle from a doubly linked list". */
static void sockptyr_lst_remove(struct sockptyr_hdl **head,
                                struct sockptyr_hdl *hdl)
{
    if (hdl->next != NULL) {
        hdl->next->prev = hdl->prev;
    }
    if (hdl->prev == NULL) {
        *head = hdl->next;
    } else {
        hdl->prev->next = hdl->next;
    }
    hdl->next = hdl->prev = NULL;
}

