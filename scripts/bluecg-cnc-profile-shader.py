#!/usr/bin/env python3
"""Generate an experimental cnc-ddraw bilinear shader matching a captured GDI ICC profile."""
import argparse
import hashlib
import io
import json
import math
import struct
from pathlib import Path
from PIL import Image, ImageCms


def tags(data):
    if len(data) < 132 or data[36:40] != b'acsp' or data[16:24] != b'RGB XYZ ':
        raise ValueError('requires an RGB/XYZ ICC profile')
    if struct.unpack_from('>I', data)[0] != len(data):
        raise ValueError('invalid ICC size')
    count = struct.unpack_from('>I', data, 128)[0]
    if count > 256 or 132 + 12*count > len(data):
        raise ValueError('invalid ICC tag table')
    result = {}
    for i in range(count):
        key, offset, size = struct.unpack_from('>4sII', data, 132+12*i)
        if offset < 132+12*count or size < 8 or offset+size > len(data):
            raise ValueError('invalid ICC tag extent')
        result[key] = data[offset:offset+size]
    if any(key.startswith((b'A2B', b'B2A')) for key in result):
        raise ValueError('LUT ICC profiles are unsupported; no shader generated')
    return result


def matrix(data):
    entries = tags(data)
    columns = []
    for key in (b'rXYZ', b'gXYZ', b'bXYZ'):
        value = entries.get(key, b'')
        if len(value) != 20 or value[:4] != b'XYZ ':
            raise ValueError('requires three matrix colorants')
        columns.append([x/65536 for x in struct.unpack_from('>iii', value, 8)])
    return [[columns[c][r] for c in range(3)] for r in range(3)]


def inverse(m):
    a,b,c = m[0]; d,e,f = m[1]; g,h,i = m[2]
    determinant = a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)
    if not math.isfinite(determinant) or abs(determinant) < 1e-8:
        raise ValueError('singular ICC matrix')
    return [[x/determinant for x in row] for row in
            ((e*i-f*h,c*h-b*i,b*f-c*e),(f*g-d*i,a*i-c*g,c*d-a*f),(d*h-e*g,b*g-a*h,a*e-b*d))]


def coefficients(icc):
    entries = tags(icc)
    gammas = []
    for key in (b'rTRC', b'gTRC', b'bTRC'):
        value = entries.get(key, b'')
        if len(value) < 14 or value[:4] != b'curv' or struct.unpack_from('>I',value,8)[0] != 1:
            raise ValueError('only single-gamma matrix profiles are supported')
        gamma = struct.unpack_from('>H',value,12)[0]/256
        if not 0.5 <= gamma <= 4:
            raise ValueError('unsupported ICC gamma')
        gammas.append(gamma)
    source = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB'))
    src = matrix(source.tobytes()); dst = inverse(matrix(icc))
    conversion = [[sum(dst[r][k]*src[k][c] for k in range(3)) for c in range(3)] for r in range(3)]
    return conversion, gammas


def convert(rgb, conversion, gammas):
    values = [v/255 for v in rgb]
    linear = [v/12.92 if v <= 0.04045 else ((v+0.055)/1.055)**2.4 for v in values]
    target = [max(0,min(1,sum(row[k]*linear[k] for k in range(3)))) for row in conversion]
    return tuple(round(255*v**(1/gamma)) for v,gamma in zip(target,gammas))


def validate(icc, conversion, gammas):
    levels = [round(i*255/16) for i in range(17)]
    colors = [(r,g,b) for r in levels for g in levels for b in levels] + [(v,v,v) for v in range(256)]
    image = Image.new('RGB',(len(colors),1)); image.putdata(colors)
    reference = ImageCms.profileToProfile(image, ImageCms.createProfile('sRGB'),
                 ImageCms.ImageCmsProfile(io.BytesIO(icc)), renderingIntent=0, outputMode='RGB').tobytes()
    errors = [abs(v-reference[3*i+c]) for i,rgb in enumerate(colors)
              for c,v in enumerate(convert(rgb,conversion,gammas))]
    result = dict(colors=len(colors),max_channel_error=max(errors),mean_channel_error=sum(errors)/len(errors))
    if result['max_channel_error'] > 2 or result['mean_channel_error'] > 0.25:
        raise ValueError('matrix approximation failed independent LCMS reference validation')
    return result


def shader(icc, conversion, gammas):
    rows = ['vec3('+','.join(f'{v:.12g}' for v in row)+')' for row in conversion]
    powers = ','.join(f'{1/v:.12g}' for v in gammas)
    return f'''// Experimental BlueCG-only capture-profile match; not a universal display calibration.
// Target capture ICC SHA-256: {hashlib.sha256(icc).hexdigest()}
// Regenerate and verify if the capture profile or presentation pipeline changes.
#if __VERSION__ >= 130
#define ATTR in
#ifdef VERTEX
#define VARY out
#else
#define VARY in
out vec4 FragColor;
#endif
#define SAMPLE texture
#else
#define ATTR attribute
#define VARY varying
#define SAMPLE texture2D
#define FragColor gl_FragColor
#endif
#if defined(VERTEX)
ATTR vec4 VertexCoord;
ATTR vec4 TexCoord;
VARY vec2 uv;
uniform mat4 MVPMatrix;
void main() {{ gl_Position=MVPMatrix*VertexCoord; uv=TexCoord.xy; }}
#elif defined(FRAGMENT)
VARY vec2 uv;
uniform sampler2D Texture;
float decode_srgb(float c) {{ return c<=0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4); }}
void main() {{
    vec4 sample_color=SAMPLE(Texture,uv);
    vec3 rgb=vec3(decode_srgb(sample_color.r),decode_srgb(sample_color.g),decode_srgb(sample_color.b));
    vec3 linear=vec3(dot({rows[0]},rgb),dot({rows[1]},rgb),dot({rows[2]},rgb));
    FragColor=vec4(pow(clamp(linear,0.0,1.0),vec3({powers})),sample_color.a);
}}
#endif
'''


def generate(capture, output):
    if not output.name.endswith('-bilinear.glsl'):
        raise ValueError('cnc-ddraw 7.1 needs the -bilinear.glsl suffix to select hardware linear sampling')
    with Image.open(capture) as image:
        icc = image.info.get('icc_profile')
    if not icc:
        raise ValueError('capture has no embedded ICC profile')
    conversion,gammas = coefficients(icc)
    reference = validate(icc,conversion,gammas)
    text = shader(icc,conversion,gammas)
    with output.open('x',encoding='utf-8') as file:
        file.write(text)
    return dict(icc_sha256=hashlib.sha256(icc).hexdigest(),gamma=gammas,matrix=conversion,
                reference=reference,shader_sha256=hashlib.sha256(text.encode()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    try: result = generate(args.capture,args.output)
    except (ValueError,OSError) as error: parser.error(str(error))
    print(json.dumps(result,indent=2))

if __name__ == '__main__':
    main()
