/*************************************************************************
 * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
 *
 * See LICENSE.txt for license information
 ************************************************************************/

#include "nccl.h"
#include "core.h"
#include "socket.h"
#include "net.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <poll.h>

/* Init functions */

int ncclSocketPtrSupport(int dev, int* supportedTypes) {
  *supportedTypes = NCCL_PTR_HOST;
  return 0;
}

#define MAX_IF_NAME_SIZE 16
#define MAX_IFS 16
static char ncclNetIfNames[MAX_IF_NAME_SIZE*MAX_IFS];
static union socketAddress ncclNetIfAddrs[MAX_IFS];
static int ncclNetIfs = -1;
pthread_mutex_t ncclSocketLock = PTHREAD_MUTEX_INITIALIZER;

static void initDevices() {
  if (ncclNetIfs == -1) {
    pthread_mutex_lock(&ncclSocketLock);
    if (ncclNetIfs == -1) {
      ncclNetIfs = findInterfaces(ncclNetIfNames, ncclNetIfAddrs, MAX_IF_NAME_SIZE, MAX_IFS);
      INFO("NET/Socket : %d interfaces found", ncclNetIfs);
    }
    pthread_mutex_unlock(&ncclSocketLock);
  }
}

int ncclSocketDevices(int* ndev, int** scores) {
  initDevices();
  *ndev = ncclNetIfs;
  int* sc = (int*)malloc(ncclNetIfs*sizeof(int));
  for (int i=0; i<ncclNetIfs; i++) sc[i] = 1;
  *scores = sc;
  return ncclSuccess;
}

static ncclResult_t GetSocketAddr(int dev, union socketAddress* addr) {
  if (ncclNetIfs == -1) initDevices();
  if (dev > ncclNetIfs) return ncclInternalError;
  memcpy(addr, ncclNetIfAddrs+dev, sizeof(*addr));
  return ncclSuccess;
}

/* Communication functions */

struct ncclSocketHandle {
  union socketAddress connectAddr;
};

struct ncclSocketRequest {
  int used;
  int size;
};

struct ncclSocketReqs {
  struct ncclSocketRequest* requests;
};

struct ncclSocketComm {
  int fd;
  struct ncclSocketReqs reqs;
};

struct ncclSocketComm* ncclSocketNewComm() {
  struct ncclSocketComm* comm = (struct ncclSocketComm*)malloc(sizeof(struct ncclSocketComm));
  comm->reqs.requests = NULL;
  comm->fd = -1;
  return comm;
}

int ncclSocketListen(int dev, void* opaqueHandle, void** listenComm) {
  struct ncclSocketComm* comm = ncclSocketNewComm();
  struct ncclSocketHandle* handle = (struct ncclSocketHandle*) opaqueHandle;
  static_assert(sizeof(struct ncclSocketHandle) < NCCL_NET_HANDLE_MAXSIZE, "ncclSocketHandle size too large");
  NCCLCHECK(GetSocketAddr(dev, &(handle->connectAddr)));
  NCCLCHECK(createListenSocket(&comm->fd, &handle->connectAddr));
  *listenComm = comm;
  return 0;
}

int ncclSocketConnect(int dev, void* opaqueHandle, void** sendComm) {
  if (ncclNetIfs == -1) initDevices();
  if (dev > ncclNetIfs) return ncclInternalError;
  struct ncclSocketComm* comm = ncclSocketNewComm();
  struct ncclSocketHandle* handle = (struct ncclSocketHandle*) opaqueHandle;
  NCCLCHECK(connectAddress(&handle->connectAddr, &ncclNetIfAddrs[dev], &comm->fd));
  *sendComm = comm;
  return 0;
}

int ncclSocketAccept(void* listenComm, void** recvComm) {
  struct ncclSocketComm* lComm = (struct ncclSocketComm*)listenComm;
  struct ncclSocketComm* rComm = ncclSocketNewComm();
  struct sockaddr_in sockaddr;
  socklen_t socklen = sizeof(struct sockaddr_in);
  SYSCHECKVAL(accept(lComm->fd, (struct sockaddr*)&sockaddr, &socklen), "accept", rComm->fd);
  *recvComm = rComm;
  return 0;
}

#define MAX_REQUESTS 128

ncclResult_t ncclSocketGetRequest(struct ncclSocketReqs* reqs, struct ncclSocketRequest** req) {
  if (reqs->requests == NULL) {
    reqs->requests = (struct ncclSocketRequest*)malloc(MAX_REQUESTS*sizeof(struct ncclSocketRequest));
    memset(reqs->requests, 0, MAX_REQUESTS*sizeof(struct ncclSocketRequest));
  }
  for (int i=0; i<MAX_REQUESTS; i++) {
    struct ncclSocketRequest* r = reqs->requests+i;
    if (r->used == 0) {
      r->used = 1;
      r->size = -1;
      *req = r;
      return ncclSuccess;
    }
  }
  WARN("Socket : unable to allocate requests\n");
  return ncclInternalError;
}

int ncclSocketIsend(void* sendComm, void* data, int size, int type, void** request) {
  if (type != NCCL_PTR_HOST) return 1;
  struct ncclSocketComm* comm = (struct ncclSocketComm*)sendComm;
  *request = NULL;
  NCCLCHECK(socketSend(comm->fd, &size, sizeof(int)));
  NCCLCHECK(socketSend(comm->fd, data, size));
  return 0;
}

int ncclSocketIrecv(void* recvComm, void* data, int size, int type, void** request) {
  if (type != NCCL_PTR_HOST) return 1;
  struct ncclSocketComm* comm = (struct ncclSocketComm*)recvComm;
  int recvSize;
  NCCLCHECK(socketReceive(comm->fd, &recvSize, sizeof(int)));
  if (recvSize > size) {
    WARN("Message truncated : received %d bytes instead of %d\n", recvSize, size);
    return ncclInternalError;
  }
  NCCLCHECK(socketReceive(comm->fd, data, min(recvSize, size)));
  struct ncclSocketRequest* recvReq;
  NCCLCHECK(ncclSocketGetRequest(&comm->reqs, &recvReq));
  recvReq->size = recvSize;
  *request = recvReq;
  return 0;
}

int ncclSocketFlush(void* recvComm, void* data, int size) {
  // We don't support CUDA pointers, we don't need a flush.
  return 1;
}

int ncclSocketTest(void* request, int* done, int* size) {
  *done = 1;
  struct ncclSocketRequest *r = (struct ncclSocketRequest*)request;
  if (r) {
    if (size) *size = r->size;
    r->used = 0;
  }
  return 0;
}

int ncclSocketClose(void* opaqueComm) {
  struct ncclSocketComm* comm = (struct ncclSocketComm*)opaqueComm;
  if (comm) {
    free(comm->reqs.requests);
    close(comm->fd);
    free(comm);
  }
  return 0;
}

ncclNet_t ncclNetSocket = {
  "Socket",
  ncclSocketDevices,
  ncclSocketPtrSupport,
  ncclSocketListen,
  ncclSocketConnect,
  ncclSocketAccept,
  ncclSocketIsend,
  ncclSocketIrecv,
  ncclSocketFlush,
  ncclSocketTest,
  ncclSocketClose,
  ncclSocketClose,
  ncclSocketClose
};
