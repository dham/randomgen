from __future__ import absolute_import

from libc.stdlib cimport malloc, free
from cpython.pycapsule cimport PyCapsule_New

try:
    from threading import Lock
except ImportError:
    from dummy_threading import Lock

import numpy as np
cimport numpy as np

from randomgen.common import interface
from randomgen.common cimport *
from randomgen.distributions cimport brng_t
from randomgen.entropy import random_entropy
import randomgen.pickle

np.import_array()


cdef extern from "src/pcg32/pcg32.h":

    cdef struct pcg_state_setseq_64:
        uint64_t state
        uint64_t inc

    ctypedef pcg_state_setseq_64 pcg32_random_t

    struct s_pcg32_state:
      pcg32_random_t *pcg_state

    ctypedef s_pcg32_state pcg32_state

    uint64_t pcg32_next64(pcg32_state *state)  nogil
    uint32_t pcg32_next32(pcg32_state *state)  nogil
    double pcg32_next_double(pcg32_state *state)  nogil
    void pcg32_jump(pcg32_state  *state)
    void pcg32_advance_state(pcg32_state *state, uint64_t step)
    void pcg32_set_seed(pcg32_state *state, uint64_t seed, uint64_t inc)

cdef uint64_t pcg32_uint64(void* st) nogil:
    return pcg32_next64(<pcg32_state *>st)

cdef uint32_t pcg32_uint32(void *st) nogil:
    return pcg32_next32(<pcg32_state *> st)

cdef double pcg32_double(void* st) nogil:
    return pcg32_next_double(<pcg32_state *>st)

cdef uint64_t pcg32_raw(void* st) nogil:
    return <uint64_t>pcg32_next32(<pcg32_state *> st)


cdef class PCG32:
    u"""
    PCG32(seed=None, inc=0)

    Container for the PCG-32 pseudo-random number generator.

    PCG-32 is a 64-bit implementation of O'Neill's permutation congruential
    generator ([1]_, [2]_). PCG-32 has a period of :math:`2^{64}` and supports
    advancing an arbitrary number of steps as well as :math:`2^{63}` streams.

    ``PCG32`` exposes no user-facing API except ``generator``,``state``,
    ``cffi`` and ``ctypes``. Designed for use in a ``RandomGenerator`` object.

    **Compatibility Guarantee**

    ``PCG32`` makes a guarantee that a fixed seed will always produce the same
    results.

    Parameters
    ----------
    seed : {None, long}, optional
        Random seed initializing the pseudo-random number generator.
        Can be an integer in [0, 2**64] or ``None`` (the default).
        If `seed` is ``None``, then ``PCG32`` will try to read data
        from ``/dev/urandom`` (or the Windows analog) if available. If
        unavailable, a 64-bit hash of the time and process ID is used.
    inc : {None, int}, optional
        Stream to return.
        Can be an integer in [0, 2**64] or ``None`` (the default).  If `inc` is
        ``None``, then 0 is used.  Can be used with the same seed to
        produce multiple streams using other values of inc.

    Notes
    -----
    Supports the method advance to advance the PRNG an arbitrary number of
    steps. The state of the PCG-32 PRNG is represented by 2 128-bit unsigned
    integers.

    See ``PCG32`` for a similar implementation with a smaller period.

    **Parallel Features**

    ``PCG32`` can be used in parallel applications in one of two ways.
    The preferable method is to use sub-streams, which are generated by using the
    same value of ``seed`` and incrementing the second value, ``inc``.

    >>> from randomgen import RandomGenerator, PCG32
    >>> rg = [RandomGenerator(PCG32(1234, i + 1)) for i in range(10)]

    The alternative method is to call ``advance`` on a instance to
    produce non-overlapping sequences.

    >>> rg = [RandomGenerator(PCG32(1234, i + 1)) for i in range(10)]
    >>> for i in range(10):
    ...     rg[i].advance(i * 2**32)

    **State and Seeding**

    The ``PCG32`` state vector consists of 2 unsigned 64-bit values/
    ``PCG32`` is seeded using a single 64-bit unsigned integer. In addition,
    a second 64-bit unsigned integer is used to set the stream.

    References
    ----------
    .. [1] "PCG, A Family of Better Random Number Generators",
           http://www.pcg-random.org/
    .. [2] O'Neill, Melissa E. "PCG: A Family of Simple Fast Space-Efficient
           Statistically Good Algorithms for Random Number Generation"
    """
    cdef pcg32_state *rng_state
    cdef brng_t *_brng
    cdef public object capsule
    cdef object _ctypes
    cdef object _cffi
    cdef object _generator
    cdef public object lock

    def __init__(self, seed=None, inc=0):
        self.rng_state = <pcg32_state *>malloc(sizeof(pcg32_state))
        self.rng_state.pcg_state = <pcg32_random_t *>malloc(sizeof(pcg32_random_t))
        self._brng = <brng_t *>malloc(sizeof(brng_t))
        self.seed(seed, inc)
        self.lock = Lock()

        self._brng.state = <void *>self.rng_state
        self._brng.next_uint64 = &pcg32_uint64
        self._brng.next_uint32 = &pcg32_uint32
        self._brng.next_double = &pcg32_double
        self._brng.next_raw = &pcg32_raw

        self._ctypes = None
        self._cffi = None
        self._generator = None

        cdef const char *name = "BasicRNG"
        self.capsule = PyCapsule_New(<void *>self._brng, name, NULL)

    # Pickling support:
    def __getstate__(self):
        return self.state

    def __setstate__(self, state):
        self.state = state

    def __reduce__(self):
        return (randomgen.pickle.__brng_ctor,
                (self.state['brng'],),
                self.state)

    def __dealloc__(self):
        free(self.rng_state)
        free(self._brng)

    def _benchmark(self, Py_ssize_t cnt, method=u'uint64'):
        cdef Py_ssize_t i
        if method==u'uint64':
            for i in range(cnt):
                self._brng.next_uint64(self._brng.state)
        elif method==u'double':
            for i in range(cnt):
                self._brng.next_double(self._brng.state)
        else:
            raise ValueError('Unknown method')


    def seed(self, seed=None, inc=0):
        """
        seed(seed=None, inc=0)

        Seed the generator.

        This method is called when ``PCG32`` is initialized. It can be
        called again to re-seed the generator. For details, see
        ``PCG32``.

        Parameters
        ----------
        seed : int, optional
            Seed for ``PCG32``.
        inc : int, optional
            Increment to use for PCG stream

        Raises
        ------
        ValueError
            If seed values are out of range for the PRNG.
        """
        ub =  2 ** 64
        if seed is None:
            try:
                seed = <np.ndarray>random_entropy(2)
            except RuntimeError:
                seed = <np.ndarray>random_entropy(2, 'fallback')
            seed = seed.view(np.uint64).squeeze()
        else:
            err_msg = 'seed must be a scalar integer between 0 and ' \
                      '{ub}'.format(ub=ub)
            if not np.isscalar(seed):
                raise TypeError(err_msg)
            if int(seed) != seed:
                raise TypeError(err_msg)
            if seed < 0 or seed > ub:
                raise ValueError(err_msg)

        if not np.isscalar(inc):
            raise TypeError('inc must be a scalar integer between 0 '
                            'and {ub}'.format(ub=ub))
        if inc < 0 or inc > ub or int(inc) != inc:
            raise ValueError('inc must be a scalar integer between 0 '
                             'and {ub}'.format(ub=ub))

        pcg32_set_seed(self.rng_state, <uint64_t>seed, <uint64_t>inc)

    @property
    def state(self):
        """
        Get or set the PRNG state

        Returns
        -------
        state : dict
            Dictionary containing the information required to describe the
            state of the PRNG
        """
        return {'brng': self.__class__.__name__,
                'state': {'state': self.rng_state.pcg_state.state,
                          'inc':self.rng_state.pcg_state.inc}}

    @state.setter
    def state(self, value):
        if not isinstance(value, dict):
            raise TypeError('state must be a dict')
        brng = value.get('brng', '')
        if brng != self.__class__.__name__:
            raise ValueError('state must be for a {0} '
                             'PRNG'.format(self.__class__.__name__))
        self.rng_state.pcg_state.state  = value['state']['state']
        self.rng_state.pcg_state.inc = value['state']['inc']

    def advance(self, delta):
        """
        advance(delta)

        Advance the underlying RNG as-if delta draws have occurred.

        Parameters
        ----------
        delta : integer, positive
            Number of draws to advance the RNG. Must be less than the
            size state variable in the underlying RNG.

        Returns
        -------
        self : PCG32
            RNG advanced delta steps

        Notes
        -----
        Advancing a RNG updates the underlying RNG state as-if a given
        number of calls to the underlying RNG have been made. In general
        there is not a one-to-one relationship between the number output
        random values from a particular distribution and the number of
        draws from the core RNG.  This occurs for two reasons:

        * The random values are simulated using a rejection-based method
          and so, on average, more than one value from the underlying
          RNG is required to generate an single draw.
        * The number of bits required to generate a simulated value
          differs from the number of bits generated by the underlying
          RNG.  For example, two 16-bit integer values can be simulated
          from a single draw of a 32-bit RNG.
        """
        pcg32_advance_state(self.rng_state, <uint64_t>delta)
        return self

    def jump(self, np.npy_intp iter=1):
        """
        jump(iter=1)

        Jumps the state as-if 2**32 random numbers have been generated

        Parameters
        ----------
        iter : integer, positive
            Number of times to jump the state of the rng.

        Returns
        -------
        self : PCG32
            RNG jumped iter times
        """
        return self.advance(iter * 2**32)

    @property
    def ctypes(self):
        """
        Ctypes interface

        Returns
        -------
        interface : namedtuple
            Named tuple containing CFFI wrapper

            * state_address - Memory address of the state struct
            * state - pointer to the state struct
            * next_uint64 - function pointer to produce 64 bit integers
            * next_uint32 - function pointer to produce 32 bit integers
            * next_double - function pointer to produce doubles
            * brng - pointer to the Basic RNG struct
        """

        if self._ctypes is not None:
            return self._ctypes

        import ctypes

        self._ctypes = interface(<uintptr_t>self.rng_state,
                         ctypes.c_void_p(<uintptr_t>self.rng_state),
                         ctypes.cast(<uintptr_t>&pcg32_uint64,
                                     ctypes.CFUNCTYPE(ctypes.c_uint64,
                                     ctypes.c_void_p)),
                         ctypes.cast(<uintptr_t>&pcg32_uint32,
                                     ctypes.CFUNCTYPE(ctypes.c_uint32,
                                     ctypes.c_void_p)),
                         ctypes.cast(<uintptr_t>&pcg32_double,
                                     ctypes.CFUNCTYPE(ctypes.c_double,
                                     ctypes.c_void_p)),
                         ctypes.c_void_p(<uintptr_t>self._brng))
        return self._ctypes

    @property
    def cffi(self):
        """
        CFFI interface

        Returns
        -------
        interface : namedtuple
            Named tuple containing CFFI wrapper

            * state_address - Memory address of the state struct
            * state - pointer to the state struct
            * next_uint64 - function pointer to produce 64 bit integers
            * next_uint32 - function pointer to produce 32 bit integers
            * next_double - function pointer to produce doubles
            * brng - pointer to the Basic RNG struct
        """
        if self._cffi is not None:
            return self._cffi
        try:
            import cffi
        except ImportError:
            raise ImportError('cffi is cannot be imported.')

        ffi = cffi.FFI()
        self._cffi = interface(<uintptr_t>self.rng_state,
                         ffi.cast('void *',<uintptr_t>self.rng_state),
                         ffi.cast('uint64_t (*)(void *)',<uintptr_t>self._brng.next_uint64),
                         ffi.cast('uint32_t (*)(void *)',<uintptr_t>self._brng.next_uint32),
                         ffi.cast('double (*)(void *)',<uintptr_t>self._brng.next_double),
                         ffi.cast('void *',<uintptr_t>self._brng))
        return self._cffi

    @property
    def generator(self):
        """
        Return a RandomGenerator object

        Returns
        -------
        gen : randomgen.generator.RandomGenerator
            Random generator used this instance as the core PRNG
        """
        if self._generator is None:
            from .generator import RandomGenerator
            self._generator = RandomGenerator(self)
        return self._generator