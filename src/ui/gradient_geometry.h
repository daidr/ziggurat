#ifndef ZIGGURAT_GRADIENT_GEOMETRY_H
#define ZIGGURAT_GRADIENT_GEOMETRY_H
/* Physical source-plane geometry. No retained pointers or native calls.
   The optional program specializes only stop storage at preprocessing time. */
typedef struct Constants {float frame[4],axis[4],radial[4];uint32_t control[4];int32_t output_bounds[4];float shape[4],contour[4];float positions[16][4],colors[16][4];} Constants;
_Static_assert(sizeof(Constants)==624,"HLSL cbuffer packing");
static int gradient_coordinate(double value){return isfinite(value)&&fabs(value)<=2097152.0;}
static HRESULT gradient_values(Constants *out,float x,float y,float width,float height,float radius,float stroke,
    double scale,uint32_t target_width,uint32_t target_height,const ZgBrush *key
#ifdef ZG_INTERPOLATION_VALUES
    ,const ZgInterpolationPacket *packet
#endif
) {
    if(!key||key->kind>ZG_BRUSH_CONIC||key->len<2||key->len>ZG_STOP_CAPACITY)return E_INVALIDARG;
    if(width==0||height==0)return S_FALSE;
    double left=fmax(0,floor((double)x*scale)),top=fmax(0,floor((double)y*scale));
    double right=fmin(target_width,ceil(((double)x+width)*scale)),bottom=fmin(target_height,ceil(((double)y+height)*scale));
    if(left>=right||top>=bottom)return S_FALSE;
    double ax=(double)key->x0*scale,ay=(double)key->y0*scale,bx=(double)key->x1,by=(double)key->y1;
    if(key->kind!=ZG_BRUSH_CONIC){bx*=scale;by*=scale;}
    double sx=(double)x*scale,sy=(double)y*scale,sw=(double)width*scale,sh=(double)height*scale;
    if(!gradient_coordinate(ax)||!gradient_coordinate(ay)||!gradient_coordinate(bx)||!gradient_coordinate(by)||
       !gradient_coordinate(sx)||!gradient_coordinate(sy)||!gradient_coordinate(sw)||!gradient_coordinate(sh)||
       (key->kind==1&&(bx<1.0/4096||by<1.0/4096)))return ZG_E_GRADIENT_PRECISION;
    if(key->kind==ZG_BRUSH_CONIC&&(bx<0||bx>=(float)(2*3.14159265358979323846)||(by!=1&&by!=-1)))return E_INVALIDARG;
    memset(out,0,sizeof(*out));
    Constants *v=out;
    v->frame[0]=(float)((left+right)*.5);v->frame[1]=(float)((top+bottom)*.5);v->frame[2]=1;v->frame[3]=(float)key->kind;
    /* Center the radial expansion at the nearest point of the visible box to
       the ellipse center. If a [0,1] contour reaches this box then q0<=1;
       a tall target cannot introduce a large constant that swallows stop^2. */
    if(key->kind==1){v->frame[0]=(float)fmax(left,fmin(right,ax));v->frame[1]=(float)fmax(top,fmin(bottom,ay));}
    if(key->kind==ZG_BRUSH_CONIC){v->frame[0]=(float)ax;v->frame[1]=(float)ay;}
    v->control[0]=key->len;v->output_bounds[0]=(int32_t)left;v->output_bounds[1]=(int32_t)top;v->output_bounds[2]=(int32_t)right;v->output_bounds[3]=(int32_t)bottom;
    v->shape[0]=(float)(sx-v->frame[0]);v->shape[1]=(float)(sy-v->frame[1]);v->shape[2]=(float)sw;v->shape[3]=(float)sh;v->contour[0]=radius*(float)scale;v->contour[1]=stroke*(float)scale;
    double q0=0;BOOL radial_outside=FALSE;
    if(key->kind==0){double dx=bx-ax,dy=by-ay,length=hypot(dx,dy);if(!length)return ZG_E_GRADIENT_PRECISION;v->axis[0]=(float)(dx/length);v->axis[1]=(float)(dy/length);}
    else if(key->kind==ZG_BRUSH_CONIC){v->axis[0]=(float)bx;v->axis[1]=(float)by;}
    else{
        double rx=1/bx,ry=1/by,cx=ax-v->frame[0],cy=ay-v->frame[1];
        v->axis[2]=(float)(rx*rx);v->axis[3]=(float)(ry*ry);v->radial[0]=(float)(-2*cx*rx*rx);v->radial[1]=(float)(-2*cy*ry*ry);q0=(cx*rx)*(cx*rx)+(cy*ry)*(cy*ry);
        if(q0>1){radial_outside=TRUE;v->axis[2]=v->axis[3]=v->radial[0]=v->radial[1]=0;}
    }
    for(unsigned i=0;i<key->len;i++){
        double offset=key->stops[i].offset;
        if(key->kind==1){v->positions[i][0]=radial_outside?0:(float)(q0-offset*offset);v->positions[i][1]=(float)offset;}
        else if(key->kind==ZG_BRUSH_CONIC)v->positions[i][0]=(float)offset;
        else{
            double px=(1-offset)*ax+offset*bx,py=(1-offset)*ay+offset*by;
            v->positions[i][0]=(float)((px-v->frame[0])*v->axis[0]+(py-v->frame[1])*v->axis[1]);
        }
#ifdef ZG_INTERPOLATION_VALUES
        uint32_t rgba=key->stops[i].rgba;
        v->positions[i][2]=(float)(rgba>>16);v->positions[i][3]=(float)(rgba&65535);
        memcpy(v->colors[i],packet->colors[i],sizeof(v->colors[i]));
#else
        uint32_t rgba=key->stops[i].rgba;double alpha=(rgba&255)/255.0;
        v->colors[i][0]=(float)((rgba>>24)/255.0*alpha);v->colors[i][1]=(float)(((rgba>>16)&255)/255.0*alpha);v->colors[i][2]=(float)(((rgba>>8)&255)/255.0*alpha);v->colors[i][3]=(float)alpha;
#endif
    }
#ifdef ZG_INTERPOLATION_VALUES
    v->control[1]=packet->space;
#endif
    return S_OK;
}
#endif
