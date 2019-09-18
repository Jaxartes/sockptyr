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
/* Compile with -DUSE_INOTIFY=1 on Linux to take advantage of inotify(7) */
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
#endif
#include <sys/socket.h>

static const char *handle_prefix = "sockptyr_";

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

struct sockptyr_hdl {
    /* Info about a single handle in sockptyr.  They're
     * organized in a kind of tree under 'struct sockptyr_data', its
     * structure associated with their handle strings:
     *      sd->rhdl is "sockptyr_0"
     *      sd->rhdl->children[0] is "sockptyr_1"
     *      sd->rhdl->children[1] is "sockptyr_2"
     *      sd->rhdl->children[0]->children[0] is "sockptyr_3"
     *      generally the relation is:
     *          node->children[m]->num == node->num * 2 + m + 1
     * For each node sh, sh->count is a count of that handle and
     * all its descendants that are currently allocated.
     */
    struct sockptyr_data *sd; /* global data */
    int num; /* handle number */
    struct sockptyr_hdl *children[2], *parent;
    int count;

    enum {
        usage_empty, /* just a placeholder, not counted, available for use */
        usage_conn, /* a connection, identifiable by handle */
        usage_mondir, /* a monitored directory */
        usage_exec, /* program started by "sockptyr exec" if I ever
                     * decide to implement it
                     */
    } usage;

    union {
        struct sockptyr_conn *u_conn; /* if usage == usage_conn */
    } u;
};

struct sockptyr_data {
    /* state of the whole sockptyr instance on a given interpreter */

    Tcl_Interp *interp; /* interpreter for event handling etc */
    struct sockptyr_hdl *rhdl; /* root handle "sockptyr_0" */
};

static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd);
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls);
static void sockptyr_cleanup(ClientData cd);
static int sockptyr_cmd(ClientData cd, Tcl_Interp *interp,
                        int argc, const char *argv[]);
static int sockptyr_cmd_open_pty(ClientData cd, Tcl_Interp *interp,
                                 int argc, const char *argv[]);
static int sockptyr_cmd_monitor_directory(ClientData cd, Tcl_Interp *interp,
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
static void sockptyr_cmd_dbg_handles_rec(Tcl_Interp *interp,
                                         struct sockptyr_hdl *hdl, int num,
                                         char *err, int errsz);
static int sockptyr_cmd_info(ClientData cd, Tcl_Interp *interp,
                             int argc, const char *argv[]);
static void sockptyr_clobber_handle(struct sockptyr_hdl *hdl, int rec);
static void sockptyr_init_conn(struct sockptyr_hdl *hdl, int fd, int code);
static void sockptyr_close_conn(struct sockptyr_hdl *hdl);
static void sockptyr_register_conn_handler(struct sockptyr_hdl *hdl);
static void sockptyr_conn_handler(ClientData cd, int mask);
static void sockptyr_conn_event(struct sockptyr_hdl *hdl,
                                char *errkw, char *errstr);

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
    sd->rhdl = NULL;
    sd->interp = interp;

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
    } else if (!strcmp(argv[1], "monitor_directory")) {
        return(sockptyr_cmd_monitor_directory(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "link")) {
        return(sockptyr_cmd_link(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "onclose")) {
        return(sockptyr_cmd_onclose(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "onerror")) {
        return(sockptyr_cmd_onerror(cd, interp, argc - 2, argv + 2));
    } else if (!strcmp(argv[1], "info")) {
        return(sockptyr_cmd_info(cd, interp, argc - 2, argv + 2));
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

    sockptyr_clobber_handle(sd->rhdl, 1);
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
    sockptyr_init_conn(hdl, fd, 'p');
    
    /* return a handle string that leads back to 'hdl'; and the PTY filename */
    snprintf(rb, sizeof(rb), "%s%d %s",
             handle_prefix, (int)hdl->num, ptsname(fd));
    Tcl_SetResult(interp, rb, TCL_VOLATILE);
    return(TCL_OK);
}

static int sockptyr_cmd_monitor_directory(ClientData cd, Tcl_Interp *interp,
                                          int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;

    Tcl_SetResult(interp, "unimplemented", TCL_STATIC); /* XXX */
    return(TCL_ERROR);
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
        conns[i] = hdls[i]->u.u_conn;
    }

    /* unlink them from whatever they were on before */
    for (i = 0; i < argc; ++i) {
        if (conns[i]->linked) {
            conns[i]->linked->u.u_conn->linked = NULL;
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

    resp = isonerror ? &(hdl->u.u_conn->onerror) : &(hdl->u.u_conn->onclose);
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
 * return a pointer to it.  Also adjusts the 'count' value(s) above it.
 */
static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd)
{
    int num; /* handle number */
    struct sockptyr_hdl **hdl; /* handle struct or where it would go */
    struct sockptyr_hdl *thumb, *parent;
    int branch;

    /* find something low and empty, or where it would go */
    num = 0;
    hdl = &(sd->rhdl);
    parent = NULL;
    while (*hdl && (*hdl)->usage != usage_empty) {
        if (!(*hdl)->children[0]) {
            branch = 0;
        } else if (!(*hdl)->children[1]) {
            branch = 1;
        } else if ((*hdl)->children[0]->count <=
                   (*hdl)->children[1]->count) {
            branch = 0;
        } else {
            branch = 1;
        }
        parent = *hdl;
        hdl = &((*hdl)->children[branch]);
        num = num * 2 + 1 + branch;
    }

    if (!*hdl) {
        /* allocate a new one */
        *hdl = (void *)ckalloc(sizeof(**hdl));
        memset(*hdl, 0, sizeof(**hdl));
        (*hdl)->usage = usage_empty;
        (*hdl)->count = 0;
        (*hdl)->children[0] = NULL;
        (*hdl)->children[1] = NULL;
        (*hdl)->num = num;
        (*hdl)->parent = parent;
        (*hdl)->sd = sd;
    }

    /* account for it being put to use */
    for (thumb = *hdl; thumb; thumb = thumb->parent) {
        thumb->count++;
    }

    return(*hdl);
}

/* sockptyr_lookup_handle() -- look up the specified handle, and return
 * it, or NULL if not found or not allocated.
 */
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls)
{
    int hdln, branch;
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

    hdl = sd->rhdl;
    while (hdl && hdln) {
        hdln -= 1;
        branch = hdln & 1;
        hdln >>= 1;
        hdl = hdl->children[branch];
    }
    if (hdl && hdl->usage == usage_empty) {
        hdl = NULL; /* handle not in use */
    }
    return(hdl);
}

/* sockptyr_clobber_handle() -- Clean up handle 'hdl' and
 * all others under it.  This could, sometimes, free the sockptyr_hdl,
 * but doesn't; simpler to leave it around unused until/unless we want
 * it again.  If 'rec' is nonzero, will recurse to subtrees.
 */
static void sockptyr_clobber_handle(struct sockptyr_hdl *hdl, int rec)
{
    struct sockptyr_hdl *thumb;

    if (!hdl) return; /* nothing to do */

    for (thumb = hdl; thumb; thumb = thumb->parent) {
        if (thumb->usage != usage_empty) {
            thumb->count--;
        }
    }

    if (rec && hdl->children[0]) {
        sockptyr_clobber_handle(hdl->children[0], rec);
        hdl->children[0] = NULL;
    }
    if (rec && hdl->children[1]) {
        sockptyr_clobber_handle(hdl->children[1], rec);
        hdl->children[1] = NULL;
    }

    switch (hdl->usage) {
    case usage_empty:
        /* nothing more to do */
        break;
    case usage_conn:
        {
            struct sockptyr_conn *conn = hdl->u.u_conn;
            if (conn) {
                if (conn->fd >= 0) {
                    Tcl_DeleteFileHandler(conn->fd);
                    close(conn->fd);
                    conn->fd = -1;
                }
                if (conn->linked) {
                    conn->linked->u.u_conn->linked = NULL;
                    conn->linked = NULL;
                }
                ckfree((void *)conn->buf);
                ckfree((void *)conn);
                if (conn->onclose) ckfree(conn->onclose);
                if (conn->onerror) ckfree(conn->onerror);
                hdl->u.u_conn = NULL;
            }
        }
        break;
    case usage_mondir:
        /* XXX */
        break;
    default:
        /* shouldn't happen */
        --*(unsigned *)1; /* this is intended to crash */
        break;
    }
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
    hdl->u.u_conn = conn = (void *)ckalloc(sizeof(*conn));
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

    Tcl_SetResult(interp, "", TCL_STATIC);
    err[0] = '\0';
    sockptyr_cmd_dbg_handles_rec(interp, sd->rhdl, 0, err, sizeof(err));
    if (err[0]) {
        Tcl_AppendElement(interp, "err");
        Tcl_AppendElement(interp, err);
    }

    return(TCL_OK);
}

/* sockptyr_cmd_dbg_handles_rec() -- recursive part of
 * sockptyr_cmd_dbg_handles().
 */
static void sockptyr_cmd_dbg_handles_rec(Tcl_Interp *interp,
                                         struct sockptyr_hdl *hdl, int num,
                                         char *err, int errsz)
{
    int i, ecount;
    char buf[512];

    if (hdl == NULL) return; /* nothing to do */

    if (hdl->num != num && !err[0]) {
        snprintf(err, errsz, "num wrong, got %d exp %d",
                 (int)hdl->num, (int)num);
    }
    ecount = ((hdl->children[0] ? hdl->children[0]->count : 0) +
              (hdl->children[1] ? hdl->children[1]->count : 0) +
              (hdl->usage != usage_empty ? 1 : 0));
    if (hdl->count != ecount && !err[0]) {
        snprintf(err, errsz, "on %d count wrong, got %d exp %d",
                 (int)hdl->num, (int)hdl->count, (int)ecount);
    }

    snprintf(buf, sizeof(buf), "%d count", (int)hdl->num);
    Tcl_AppendElement(interp, buf);
    snprintf(buf, sizeof(buf), "%d", (int)hdl->count);
    Tcl_AppendElement(interp, buf);

    for (i = 0; i < 2; ++i) {
        snprintf(buf, sizeof(buf), "%d children %d", (int)hdl->num, (int)i);
        Tcl_AppendElement(interp, buf);
        if (hdl->children[i]) {
            snprintf(buf, sizeof(buf), "%d", (int)hdl->children[i]->num);
            if (hdl->children[i]->parent != hdl && !err[0]) {
                snprintf(err, errsz,
                         "on %d bad parent pointer, got %d exp %d",
                         (int)hdl->children[i]->num,
                         (int)(hdl->children[i]->parent ?
                               hdl->children[i]->parent->num : -1),
                         (int)hdl->num);
            }
        } else {
            buf[0] = '\0';
        }
        Tcl_AppendElement(interp, buf);
    }

    snprintf(buf, sizeof(buf), "%d usage", (int)hdl->num);
    Tcl_AppendElement(interp, buf);
    switch (hdl->usage) {
    case usage_empty:   Tcl_AppendElement(interp, "empty"); break;
    case usage_conn:    Tcl_AppendElement(interp, "conn"); break;
    case usage_mondir:  Tcl_AppendElement(interp, "mondir"); break;
    case usage_exec:    Tcl_AppendElement(interp, "exec"); break;
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
        /* nothing to do */
        break;
    case usage_conn:
        /* connection-specific stuff */
        {
            struct sockptyr_conn *conn = hdl->u.u_conn;
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
                else if (conn->linked->u.u_conn->linked != hdl && !err[0]) {
                    snprintf(err, errsz, "%d links to %d links to %d",
                             (int)hdl->num,
                             (int)conn->linked->num,
                             (int)(conn->linked->u.u_conn->linked ?
                                   conn->linked->u.u_conn->linked->num : -1));
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
    case usage_mondir:
        /* nothing to do (yet) */
        break;
    case usage_exec:
        /* nothing to do (yet?) */
        break;
    }

    for (i = 0; i < 2; ++i) {
        if (hdl->children[i]) {
            sockptyr_cmd_dbg_handles_rec(interp, hdl->children[i],
                                         hdl->num * 2 + 1 + i, err, errsz);
        }
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

/* sockptyr_register_conn_handler(): For the given handle (which is
 * assumed to refer to a connection) set/clear file event handlers as
 * appropriate to handle the events that this connection is able to
 * deal with at the moment.
 */
static void sockptyr_register_conn_handler(struct sockptyr_hdl *hdl)
{
    int mask = 0;
    struct sockptyr_conn *conn = hdl->u.u_conn;

    if (conn->fd < 0) {
        /* nothing to do */
        return;
    }

    if (conn->buf_empty || conn->buf_in != conn->buf_out) {
        /* buffer isn't full; we can receive into it */
        mask |= TCL_READABLE;
    }
    if (conn->linked && !conn->linked->u.u_conn->buf_empty) {
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
    conn = hdl->u.u_conn;
    assert(conn != NULL);

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
        {
            int e = errno;
#if 0
            fprintf(stderr, "read(): on %d, len %d rv %d errno %d\n",
                    (int)hdl->num, (int)len, (int)rv, (int)e);
#endif
            errno = e;
        }
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
        !conn->linked->u.u_conn->buf_empty) {

        lconn = conn->linked->u.u_conn;
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
    struct sockptyr_conn *conn = hdl->u.u_conn;
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
    struct sockptyr_conn *conn = hdl->u.u_conn;

    if (conn->fd >= 0) {
        Tcl_DeleteFileHandler(conn->fd);
        close(conn->fd);
        conn->fd = -1;
    }
    sockptyr_conn_event(hdl, NULL, NULL);
    sockptyr_clobber_handle(hdl, 0);
}
