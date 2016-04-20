/*************************************************************************
 * Copyright (c) 2015, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ************************************************************************/

#ifndef enqueue_h_
#define enqueue_h_

#include "core.h"

/* Syncronize previous collective (if in different stream) and enqueue
 * collective. Work is performed asynchronously with the host thread.
 * The actual collective should be a functor with the
 * following signature.
 * ncclResult_t collective(void* sendbuff, void* recvbuff,
 *                         int count, ncclDataType_t type, ncclRedOp_t op,
 *                         int root, ncclComm_t comm);
 * The collective can assume that the appropriate cuda device has been set. */
template<typename ColFunc>
ncclResult_t enqueue(ColFunc colfunc,
                     const void* sendbuff,
                     void* recvbuff,
                     int count,
                     ncclDataType_t type,
                     ncclRedOp_t op,
                     int root,
                     ncclComm_t comm,
                     cudaStream_t stream)
{
  // No need for a mutex here because we assume that all enqueue operations happen in a fixed
  // order on all devices. Thus, thread race conditions SHOULD be impossible.

  if (stream != comm->prevStream) { // sync required for calls in different streams
    comm->prevStream = stream;
    CUDACHECK( cudaStreamWaitEvent(stream, comm->doneEvent, 0) );
  }

  // Launch the collective here
  ncclResult_t ret = colfunc(sendbuff, recvbuff, count, type, op, root, comm, stream);

  // Always have to record done event because we don't know what stream next
  // collective will be in.
  CUDACHECK( cudaEventRecord(comm->doneEvent, stream) );
  return ret;
}

#endif // End include guard

