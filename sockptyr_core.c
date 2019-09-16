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
#include <tcl.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#if USE_INOTIFY
#include <sys/inotify.h>
#endif
#include <sys/socket.h>

static const char *handle_prefix = "sockptyr_";

struct sockptyr_conn {
    /* connection specific information in sockptyr */
    int fd;
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
    /* state of the whole sockptyr instance */

    struct sockptyr_hdl *rhdl; /* root handle "sockptyr_0" */
};

static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd);
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls);
static int sockptyr_cmd(ClientData d, Tcl_Interp *interp,
                        int argc, const char *argv[]);
static int sockptyr_cmd_open_pty(ClientData d, Tcl_Interp *interp,
                                 int argc, const char *argv[]);
static int sockptyr_cmd_monitor_directory(ClientData d, Tcl_Interp *interp,
                                          int argc, const char *argv[]);
static int sockptyr_cmd_link(ClientData d, Tcl_Interp *interp,
                             int argc, const char *argv[]);
static int sockptyr_cmd_onclose(ClientData d, Tcl_Interp *interp,
                                int argc, const char *argv[]);
static int sockptyr_cmd_dbg_handles(ClientData d, Tcl_Interp *interp);
static void sockptyr_cmd_dbg_handles_rec(Tcl_Interp *interp,
                                         struct sockptyr_data *sd,
                                         struct sockptyr_hdl *hdl, int num,
                                         char *err, int errsz);
static void sockptyr_clobber_handle(struct sockptyr_data *sd,
                                    struct sockptyr_hdl *hdl, int rec);
static void sockptyr_init_conn(struct sockptyr_data *sd,
                               struct sockptyr_hdl *hdl, int fd, int code);

/*
 * Sockptyr_Init() -- The only external interface of "sockptyr_core.c" this
 * is run when you do "load $filename sockptyr" in Tcl.  It in turn registers
 * our commands and sets things up and stuff.
 */
int Sockptyr_Init(Tcl_Interp *interp)
{
    struct sockptyr_data *sd;

    sd = ckalloc(sizeof(*sd));
    memset(sd, 0, sizeof(*sd));
    sd->rhdl = NULL;

    Tcl_CreateCommand(interp, "sockptyr",
                      &sockptyr_cmd, sd, &sockptyr_cleanup);
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

    sockptyr_clobber_handle(sd, sd->rhdl, 1);
    ckfree(sd);
}

/* Tcl command "sockptyr open_pty" -- Open a PTY and return a handle for it
 * and file pathname.
 */
static int sockptyr_cmd_open_pty(ClientData d, Tcl_Interp *interp,
                                 int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    struct sockptyr_hdl *sh;
    char rb[128], *pty;
    int fd;

    /* get a handle we can use for our result */
    sh = sockptyr_allocate_handle(sd);
    fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (fd < 0) {
        snprintf(rb, sizeof(rb), "sockptyr open_pty: %s", strerror(errno));
        Tcl_SetResult(interp, rb, TCL_VOLATILE);
        return(TCL_ERROR);
    }
    sockptyr_init_conn(sd, sh, fd, 'p');
    
    /* return a handle string that leads back to 'sh'; and the PTY filename */
    snprintf(rb, sizeof(rb), "%s%d %s",
             handle_prefix, (int)sh->num, ptsname(fd));
    Tcl_SetResult(interp, rb, TCL_VOLATILE);
    return(TCL_OK);
}

static int sockptyr_cmd_monitor_directory(ClientData d, Tcl_Interp *interp,
                                          int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;

    Tcl_SetResult(interp, "unimplemented", TCL_STATIC);
    return(TCL_ERROR);
}

static int sockptyr_cmd_link(ClientData d, Tcl_Interp *interp,
                             int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;

    Tcl_SetResult(interp, "unimplemented", TCL_STATIC);
    return(TCL_ERROR);
}

static int sockptyr_cmd_onclose(ClientData d, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;

    Tcl_SetResult(interp, "unimplemented", TCL_STATIC);
    return(TCL_ERROR);
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
        *hdl = ckalloc(sizeof(**hdl));
        memset(*hdl, 0, sizeof(**hdl));
        (*hdl)->usage = usage_empty;
        (*hdl)->count = 0;
        (*hdl)->children[0] = NULL;
        (*hdl)->children[1] = NULL;
        (*hdl)->num = num;
        (*hdl)->parent = parent;
    }

    /* account for it being put to use */
    for (thumb = *hdl; thumb; thumb = thumb->parent) {
        thumb->count++;
    }
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
        hdln >> 1;
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
static void sockptyr_clobber_handle(struct sockptyr_data *sd,
                                     struct sockptyr_hdl *hdl, int rec)
{
    struct sockptyr_hdl *thumb;

    if (!hdl) return; /* nothing to do */

    for (thumb = hdl; thumb; thumb = thumb->parent) {
        if (thumb->usage != usage_empty) {
            thumb->count--;
        }
    }

    if (rec && hdl->children[0]) {
        sockptyr_clobber_handle(sd, hdl->children[0], rec);
        hdl->children[0] = NULL;
    }
    if (rec && hdl->children[1])
        sockptyr_clobber_handle(sd, hdl->children[1], rec);
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
                ckfree(conn);
                hdl->u.u_conn = NULL;
            }
        }
        break;
    case usage_mondir:
        /* XXX */
        break;
    case usage_empty:
        /* nothing to do */
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
static void sockptyr_init_conn(struct sockptyr_data *sd,
                               struct sockptyr_hdl *hdl, int fd, int code)
{
    struct sockptyr_conn *conn;

    hdl->usage = usage_conn;
    hdl->u.u_conn = conn = ckalloc(sizeof(*conn));
    memset(conn, 0, sizeof(*conn));
    conn->fd = fd;
    /* XXX Tcl_CreateFileHandler() probably indirectly */
}

/* Tcl command "sockptyr dbg_handles" -- returns a list (of name value
 * pairs like in setting an array) about the allocation of handles; giving
 * things like type and links and how they fit together.  For debugging
 * in case the name didn't make that clear.
 */
static int sockptyr_cmd_dbg_handles(ClientData d, Tcl_Interp *interp)
{
    char err[512], buf[512];
    struct sockptyr_data *sd = d;
    struct sockptyr_hdl *hdl;
    int num, ecount, i;

    Tcl_SetResult(interp, "", TCL_STATIC);
    err[0] = '\0';
    sockptyr_cmd_dbg_handles_rec(interp, sd, sd->rhdl, 0, err, sizeof(err));
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
                                         struct sockptyr_data *sd,
                                         struct sockptyr_hdl *hdl, int num,
                                         char *err, int errsz)
{
    int i, ecount;
    char buf[512];

    if (hdl->num != num && !err[0]) {
        snprintf(err, errsz, "num wrong, got %d exp %d",
                 (int)hdl->num, (int)num);
    }
    ecount = ((hdl->children[0] ? hdl->children[0] : 0) +
              (hdl->children[1] ? hdl->children[1] : 0) +
              (hdl->usage == usage_empty ? 1 : 0));
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
        snprintf(buf, sizeof(buf), "%d", (int)hdl->usage);
        Tcl_AppendElement(interp, buf);
        break;
    }

    for (i = 0; i < 2; ++i) {
        if (hdl->children[i]) {
            sockptyr_cmd_dbg_handles_rec(interp, sd, hdl->children[i],
                                         hdl->num * 2 + 1 + i, err, errsz);
        }
    }
}
