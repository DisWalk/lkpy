from cpython cimport array
import array
import pandas as pd
import numpy as np
cimport numpy as np
from cython.parallel cimport parallel, prange, threadid
from libc.stdlib cimport malloc, free, realloc, abort
cimport openmp
import logging

_logger = logging.getLogger('_item_knn')

cdef struct TmpResults:
    size_t size
    size_t capacity
    np.int64_t *items
    np.int64_t *nbrs
    np.float_t *sims

cdef TmpResults* tr_new(size_t cap) nogil:
    cdef TmpResults* tr = <TmpResults*> malloc(sizeof(TmpResults))

    if tr == NULL:
        abort()

    tr.size = 0
    tr.capacity = 0
    tr.items = <np.int64_t*> malloc(sizeof(np.int64_t) * cap)
    if tr.items == NULL:
        abort()
    tr.nbrs = <np.int64_t*> malloc(sizeof(np.int64_t) * cap)
    if tr.nbrs == NULL:
        abort()
    tr.sims = <np.float_t*> malloc(sizeof(np.float_t) * cap)
    if tr.sims == NULL:
        abort()

    return tr

cdef void tr_free(TmpResults* self) nogil:
    free(self.items)
    free(self.nbrs)
    free(self.sims)
    free(self)

cdef void tr_ensure_capacity(TmpResults* self, size_t n) nogil:
    cdef size_t tgt
    if n > self.capacity:
        tgt = self.capacity * 2
        if n >= tgt:
            tgt = n
        self.items = <np.int64_t*> realloc(self.items, sizeof(np.int64_t) * tgt)
        if self.items == NULL:
            abort()
        self.nbrs = <np.int64_t*> realloc(self.nbrs, sizeof(np.int64_t) * tgt)
        if self.nbrs == NULL:
            abort()
        self.sims = <np.float_t*> realloc(self.sims, sizeof(np.float_t) * tgt)
        if self.sims == NULL:
            abort()
        self.capacity = tgt


cpdef double sparse_dot(int [:] ks1, double [:] vs1, int[:] ks2, double [:] vs2) nogil:
    cdef double sum = 0
    cdef size_t n1 = ks1.shape[0]
    cdef size_t n2 = ks2.shape[0]
    cdef int i1 = 0
    cdef int i2 = 0
    cdef int k1, k2

    while i1 < n1 and i2 < n2:
        k1 = ks1[i1]
        k2 = ks2[i2]
        if k1 < k2:
            i1 += 1
        elif k2 < k1:
            i2 += 1
        else:
            sum += vs1[i1] * vs2[i2]
            i1 += 1
            i2 += 1

    return sum


cpdef sim_matrix(int nusers, int nitems,
                 np.int64_t[:] iu_items, np.int64_t[:] iu_users,
                 np.int64_t[:] ui_users, np.int64_t[:] ui_items, np.float_t[:] ui_ratings,
                 double threshold):
    iu_istart_v = np.zeros(nitems + 1, dtype=np.int64)
    cdef np.int64_t[:] iu_istart = iu_istart_v
    ui_ustart_v = np.zeros(nusers + 1, dtype=np.int64)
    cdef np.int64_t[:] ui_ustart = ui_ustart_v
    cdef np.int64_t u, i, j, nbr, iidx, uidx
    cdef np.int64_t a, b
    cdef double ur
    cdef double * work_vec
    cdef TmpResults* tres
    dbl_tmpl = array.array('d')

    neighborhoods = []

    assert iu_istart.shape[0] == nitems + 1
    assert ui_ustart.shape[0] == nusers + 1
    assert iu_items.shape[0] == iu_users.shape[0]

    # set up the item & user start records
    for a in range(iu_items.shape[0]):
        b = iu_items[a]
        if iu_istart[b] == 0 and b > 0:
            # update
            iu_istart[b] = a
    iu_istart[nitems] = iu_items.shape[0]
    for a in range(ui_users.shape[0]):
        b = ui_users[a]
        if ui_ustart[b] == 0 and b > 0:
            # update
            ui_ustart[b] = a
    ui_ustart[nusers] = ui_users.shape[0]

    with nogil, parallel():
        tres = tr_new(nitems)
        work_vec = <double*> malloc(sizeof(double) * nitems)
        
        for i in prange(nitems, schedule='dynamic', chunksize=10):
            for j in range(nitems):
                work_vec[j] = 0

            for uidx in range(iu_istart[i], iu_istart[i+1]):
                u = iu_users[uidx]
                # find user's rating for this item
                for iidx in range(ui_ustart[u], ui_ustart[u+1]):
                    if ui_items[iidx] == i:
                        ur = ui_ratings[iidx]
                        break
                # accumulate pieces of dot products
                for iidx in range(ui_ustart[u], ui_ustart[u+1]):
                    nbr = ui_items[iidx]
                    if nbr != i:
                        work_vec[nbr] = work_vec[nbr] + ur * ui_ratings[iidx]

            # now copy the accepted values into the results
            for j in range(nitems):
                if work_vec[j] < threshold: continue
                tr_ensure_capacity(tres, tres.size + 1)
                
                tres.items[tres.size] = i
                tres.nbrs[tres.size] = j
                tres.sims[tres.size] = work_vec[j]
                tres.size = tres.size + 1
        
        with gil:
            _logger.debug('thread %d computed %d pairs', openmp.omp_get_thread_num(), tres.size)
            if tres.size > 0:
                rframe = pd.DataFrame({'item': np.asarray(<np.int64_t[:tres.size]> tres.items).copy(),
                                       'neighbor': np.asarray(<np.int64_t[:tres.size]> tres.nbrs).copy(),
                                       'similarity': np.asarray(<np.float_t[:tres.size]> tres.sims).copy()})
                assert len(rframe) == tres.size
                neighborhoods.append(rframe)
            tr_free(tres)
            free(work_vec)
            _logger.debug('finished parallel item-item build')

    return pd.concat(neighborhoods).reset_index(drop=True)