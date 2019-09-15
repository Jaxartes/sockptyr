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

    int fd; /* file descriptor for this connection */
};

struct sockptyr_data {
    /* state of the whole sockptyr instance */

    struct sockptyr_hdl *rhdl; /* root handle "sockptyr_0" */
};

static struct sockptyr_hdl *sockptyr_allocate_handle(struct sockptyr_data *sd);
static struct sockptyr_hdl *sockptyr_lookup_handle(struct sockptyr_data *sd,
                                                   const char *hdls);
static void sockptyr_clobber_handle(struct sockptyr_data *sd,
                                    struct sockptyr_hdl *hdl);
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
    } else if (!strcmp(argv[1], "onclose)) {
        return(sockptyr_cmd_onclose(cd, interp, argc - 2, argv + 2));
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

    sockptyr_cleanup_handles(sd->rhdl); /* XXX define this */
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

    /* get a handle we can use for our result */
    sh = sockptyr_allocate_handle(sd);
    sh->fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (sh->fd < 0) {
        snprintf(rb, sizeof(rb), "sockptyr open_pty: %s", strerror(errno));
        Tcl_SetResult(interp, rb, TCL_VOLATILE);
        return(TCL_ERROR);
    }
    sh->usage = usage_conn;
    sockptyr_init_conn(sh); /* XXX implement this */
    
    /* return a handle string that leads back to 'sh'; and the PTY filename */
    snprintf(rb, sizeof(rb), "%s%d %s",
             handle_prefix, (int)sh->num, ptsname(sh->fd));
    Tcl_SetResult(interp, rb, TCL_VOLATILE);
    return(TCL_OK);
}

static int sockptyr_cmd_monitor_directory(ClientData d, Tcl_Interp *interp,
                                          int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    /* XXX */
}

static int sockptyr_cmd_link(ClientData d, Tcl_Interp *interp,
                             int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    /* XXX */

}

static int sockptyr_cmd_onclose(ClientData d, Tcl_Interp *interp,
                                int argc, const char *argv[])
{
    struct sockptyr_data *sd = cd;
    /* XXX */

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

/* sockptyr_clobber_handle() -- deallocate the specified handle (including
 * decrementing counts up the tree); free it if able.  Assumes detail stuff
 * has already been cleaned up and it's just the handle lookup structure
 * that needs taking care of now.
 */
static void sockptyr_clobber_handle(struct sockptyr_data *sd,
                                    struct sockptyr_hdl *hdl)
{
    struct sockptyr_hdl *thumb;

    if (!hdl) {
        return(NULL); /* nothing to do */
    }
    for (thumb = hdl; thumb; thumb = thumb->parent) {
        thumb->count--;
    }
    if (!(hdl->children[0] || hdl->children[1])) {
        /* can free this one! */
        ckfree(hdl);
    }
}

