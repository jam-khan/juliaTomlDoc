# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    Base.SecretBuffer()

An [`IOBuffer`](@ref)-like object where the contents will be securely wiped when garbage collected.

It is considered best practice to wipe the buffer using `Base.shred!(::SecretBuffer)` as
soon as the secure data are no longer required. When initializing with existing data, the
`SecretBuffer!` method is highly recommended to securely zero the passed argument. Avoid
initializing with and converting to `String`s as they are unable to be securely zeroed.

# Examples
```jldoctest
julia> s = Base.SecretBuffer()
SecretBuffer("*******")

julia> write(s, 's', 'e', 'c', 'r', 'e', 't')
6

julia> seek(s, 0); Char(read(s, UInt8))
's': ASCII/Unicode U+0073 (category Ll: Letter, lowercase)

julia> Base.shred!(s)
SecretBuffer("*******")

julia> eof(s)
true
```
"""
mutable struct SecretBuffer <: IO
    data::Memory{UInt8}
    size::Int
    ptr::Int

    function SecretBuffer(; sizehint=128)
        s = new(Memory{UInt8}(undef, sizehint), 0, 1)
        finalizer(final_shred!, s)
        return s
    end
end

"""
    SecretBuffer(str::AbstractString)

A convenience constructor to initialize a `SecretBuffer` from a non-secret string.

Strings are bad at keeping secrets because they are unable to be securely
zeroed or destroyed. Therefore, avoid using this constructor with secret data.
Instead of starting with a string, either construct the `SecretBuffer`
incrementally with `SecretBuffer()` and [`write`](@ref), or use a `Vector{UInt8}` with
the `Base.SecretBuffer!(::AbstractVector{UInt8})` constructor.
"""
SecretBuffer(str::AbstractString) = SecretBuffer(String(str))
function SecretBuffer(str::String)
    buf = codeunits(str)
    s = SecretBuffer(sizehint=length(buf))
    for c in buf
        write(s, c)
    end
    seek(s, 0)
    s
end
convert(::Type{SecretBuffer}, s::AbstractString) = SecretBuffer(String(s))

"""
    SecretBuffer!(data::Vector{UInt8})

Initialize a new `SecretBuffer` from `data`, securely zeroing `data` afterwards.
"""
function SecretBuffer!(d::AbstractVector{UInt8})
    len = length(d)
    s = SecretBuffer(sizehint=len)
    for i in 1:len
        write(s, d[i])
    end
    seek(s, 0)
    securezero!(d)
    s
end

function unsafe_SecretBuffer!(s::Cstring)
    if s == C_NULL
        throw(ArgumentError("cannot convert NULL to SecretBuffer"))
    end
    len = Int(ccall(:strlen, Csize_t, (Cstring,), s))
    unsafe_SecretBuffer!(convert(Ptr{UInt8}, s), len)
end
function unsafe_SecretBuffer!(p::Ptr{UInt8}, len=1)
    if p == C_NULL
        throw(ArgumentError("cannot convert NULL to SecretBuffer"))
    end
    s = SecretBuffer(sizehint=len)
    for i in 1:len
        write(s, unsafe_load(p, i))
    end
    seek(s, 0)
    unsafe_securezero!(p, len)
    s
end


show(io::IO, s::SecretBuffer) = print(io, "SecretBuffer(\"*******\")")

# Unlike other IO objects, equality is computed by value for convenience
==(s1::SecretBuffer, s2::SecretBuffer) = (s1.ptr == s2.ptr) && (s1.size == s2.size) && (UInt8(0) == _bufcmp(s1.data, s2.data, min(s1.size, s2.size)))
# Also attempt a constant time buffer comparison algorithm — the length of the secret might be
# inferred by a timing attack, but not its values.
@noinline function _bufcmp(data1::Memory{UInt8}, data2::Memory{UInt8}, sz::Int)
    res = UInt8(0)
    for i = 1:sz
        res |= xor(data1[i], data2[i])
    end
    return res
end
# All SecretBuffers hash the same to avoid leaking information or breaking consistency with ==
const _sb_hash = UInt === UInt32 ? 0x111c0925 : 0xb06061e370557428
hash(s::SecretBuffer, h::UInt) = hash(_sb_hash, h)

copy(s::SecretBuffer) = copy!(SecretBuffer(sizehint=length(s.data)), s)
function copy!(dest::SecretBuffer, src::SecretBuffer)
    if length(dest.data) != length(src.data)
        securezero!(dest.data)
        dest.data = copy(src.data)
    else
        copyto!(dest.data, src.data)
    end
    dest.size = src.size
    dest.ptr = src.ptr
    return dest
end

function write(io::SecretBuffer, b::UInt8)
    if io.ptr > length(io.data)
        # We need to resize! the array: do this manually to ensure no copies are left behind
        newdata = Memory{UInt8}(undef, (io.size+16)*2)
        copyto!(newdata, io.data)
        securezero!(io.data)
        io.data = newdata
    end
    io.size == io.ptr-1 && (io.size += 1)
    io.data[io.ptr] = b
    io.ptr += 1
    return 1
end

function write(io::IO, s::SecretBuffer)
    nb = 0
    for i in 1:s.size
        nb += write(io, s.data[i])
    end
    return nb
end

function cconvert(::Type{Cstring}, s::SecretBuffer)
    # Ensure that no nuls appear in the valid region
    if any(==(0x00), s.data[i] for i in 1:s.size)
        throw(ArgumentError("`SecretBuffers` containing nul bytes cannot be converted to C strings"))
    end
    # Add a hidden nul byte just past the end of the valid region
    p = s.ptr
    s.ptr = s.size + 1
    write(s, '\0')
    s.ptr = p
    s.size -= 1
    return s.data
end
# optional shim for manual calls to unsafe_convert:
#   unsafe_convert(::Type{Cstring}, s::SecretBuffer) = unsafe_convert(Cstring, cconvert(Cstring, s))

seek(io::SecretBuffer, n::Integer) = (io.ptr = max(min(n+1, io.size+1), 1); io)
seekend(io::SecretBuffer) = seek(io, io.size+1)
skip(io::SecretBuffer, n::Integer) = seek(io, position(io) + n)

bytesavailable(io::SecretBuffer) = io.size - io.ptr + 1
position(io::SecretBuffer) = io.ptr-1
eof(io::SecretBuffer) = io.ptr > io.size
isempty(io::SecretBuffer) = io.size == 0
function peek(io::SecretBuffer, ::Type{UInt8})
    eof(io) && throw(EOFError())
    return io.data[io.ptr]
end
function read(io::SecretBuffer, ::Type{UInt8})
    eof(io) && throw(EOFError())
    byte = io.data[io.ptr]
    io.ptr += 1
    return byte
end

function final_shred!(s::SecretBuffer)
    !isshredded(s) && @async @warn("a SecretBuffer was `shred!`ed by the GC; use `shred!` manually after use to minimize exposure.")
    shred!(s)
end

"""
    shred!(s::SecretBuffer)

Shreds the contents of a `SecretBuffer` by securely zeroing its data and
resetting its pointer and size.
This function is used to securely erase the sensitive data held in the buffer,
reducing the potential for information leaks.

# Example
```julia
s = SecretBuffer()
write(s, 's', 'e', 'c', 'r', 'e', 't')
shred!(s)  # s is now empty
```
"""
function shred!(s::SecretBuffer)
    securezero!(s.data)
    s.ptr = 1
    s.size = 0
    return s
end

isshredded(s::SecretBuffer) = all(iszero, s.data)

"""
    shred!(f::Function, x)

Applies function `f` to the argument `x` and then shreds `x`.
This function is useful when you need to perform some operations on e.g. a
`SecretBuffer` and then want to ensure that it is securely shredded afterwards.
"""
function shred!(f::Function, x)
    try
        f(x)
    finally
        shred!(x)
    end
end
