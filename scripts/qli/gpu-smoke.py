#!/usr/bin/env python3
"""Render and read back a pixel using QLI's hardware GLES driver, without a display."""
import ctypes as C
import argparse
import os
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, default=0, help='repeat full-frame render/readback for this many seconds')
args = parser.parse_args()
if not 0 <= args.seconds <= 7200:
    parser.error('--seconds must be between 0 and 7200')
dimension = 1024 if args.seconds else 1

os.environ['EGL_PLATFORM'] = 'surfaceless'
egl = C.CDLL('libEGL.so.1')
gles = C.CDLL('libGLESv2.so.2')
ptr, integer, uint = C.c_void_p, C.c_int, C.c_uint


def bind(lib, name, result, *args):
    function = getattr(lib, name)
    function.restype = result
    function.argtypes = args
    return function


get_display = bind(egl, 'eglGetDisplay', ptr, ptr)
initialize = bind(egl, 'eglInitialize', uint, ptr, C.POINTER(integer), C.POINTER(integer))
choose_config = bind(egl, 'eglChooseConfig', uint, ptr, C.POINTER(integer),
                     C.POINTER(ptr), integer, C.POINTER(integer))
bind_api = bind(egl, 'eglBindAPI', uint, uint)
create_surface = bind(egl, 'eglCreatePbufferSurface', ptr, ptr, ptr, C.POINTER(integer))
create_context = bind(egl, 'eglCreateContext', ptr, ptr, ptr, ptr, C.POINTER(integer))
make_current = bind(egl, 'eglMakeCurrent', uint, ptr, ptr, ptr, ptr)
destroy_context = bind(egl, 'eglDestroyContext', uint, ptr, ptr)
destroy_surface = bind(egl, 'eglDestroySurface', uint, ptr, ptr)
terminate = bind(egl, 'eglTerminate', uint, ptr)
get_string = bind(gles, 'glGetString', C.c_char_p, uint)
clear_color = bind(gles, 'glClearColor', None, C.c_float, C.c_float, C.c_float, C.c_float)
clear = bind(gles, 'glClear', None, uint)
read_pixels = bind(gles, 'glReadPixels', None, integer, integer, integer, integer,
                   uint, uint, ptr)
get_error = bind(gles, 'glGetError', uint)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


display = get_display(None)
context = surface = None
try:
    major, minor = integer(), integer()
    require(initialize(display, C.byref(major), C.byref(minor)), 'EGL initialization failed')
    require(bind_api(0x30A0), 'Cannot bind OpenGL ES')
    # Pbuffer, GLES2, RGBA8.
    attributes = (integer * 13)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8,
                               0x3022, 8, 0x3021, 8, 0x3038)
    config, count = ptr(), integer()
    require(choose_config(display, attributes, C.byref(config), 1, C.byref(count))
            and count.value == 1, 'No RGBA8 GLES pbuffer configuration')
    surface = create_surface(display, config, (integer * 5)(0x3057, dimension, 0x3056, dimension, 0x3038))
    context = create_context(display, config, None, (integer * 3)(0x3098, 2, 0x3038))
    require(surface and context, 'Cannot create GLES surface/context')
    require(make_current(display, surface, surface, context), 'Cannot activate GLES context')
    renderer = get_string(0x1F01).decode()
    vendor = get_string(0x1F00).decode()
    version = get_string(0x1F02).decode()
    print(f'EGL {major.value}.{minor.value}; {vendor}; {renderer}; {version}', flush=True)
    require(vendor == 'freedreno' and renderer.startswith('FD'), 'Hardware renderer required')
    pixel = (C.c_ubyte * (4 * dimension * dimension))()
    frame = 0
    deadline = time.monotonic() + args.seconds
    while True:
        green = frame % 2
        expected = [255, green * 255, 255, 255]
        clear_color(1.0, float(green), 1.0, 1.0)
        clear(0x4000)
        read_pixels(0, 0, dimension, dimension, 0x1908, 0x1401, pixel)
        require(get_error() == 0, 'GLES error during rendering/readback')
        for offset in (0, (len(pixel)//8)*4, len(pixel)-4):
            require(list(pixel[offset:offset+4]) == expected, 'GPU readback mismatch')
        frame += 1
        if time.monotonic() >= deadline:
            break
    print(f'PASS: GPU render/readback {frame} frames, {dimension}x{dimension}, {args.seconds}s')
finally:
    if display:
        make_current(display, None, None, None)
        if context:
            destroy_context(display, context)
        if surface:
            destroy_surface(display, surface)
        terminate(display)
