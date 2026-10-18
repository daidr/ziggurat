#ifndef ZIGGURAT_DOCUMENT_ACCESSIBILITY_MAPPING_H
#define ZIGGURAT_DOCUMENT_ACCESSIBILITY_MAPPING_H
#include <math.h>
#include <string.h>
#include <float.h>
_Static_assert(sizeof(ZdaMapping) == 2216, "mapping ABI");
struct ZdaMapped { BOOL active; ZdaMapping value; };
typedef struct ZdaPolygon { ZdaPoint points[ZDA_MAP_POINTS + 4]; uint32_t count; } ZdaPolygon;
static inline ZdaPoint zda_map_point(const double matrix[6], ZdaPoint p) {
    return (ZdaPoint){matrix[0]*p.x + matrix[2]*p.y + matrix[4], matrix[1]*p.x + matrix[3]*p.y + matrix[5]};
}
static inline double zda_cross(ZdaPoint a, ZdaPoint b, ZdaPoint p) {
    return (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x);
}
static inline double zda_map_distance(ZdaPoint a, ZdaPoint b, ZdaPoint p, double orientation) {
    const double first=(b.x-a.x)*(p.y-a.y),second=(b.y-a.y)*(p.x-a.x);
    const double value=(first-second)*orientation;
    /* A cached caret can lie exactly on a transformed viewport edge. Keep
       that closed boundary despite roundoff in the independently mapped pair. */
    return fabs(value)<=64*DBL_EPSILON*fmax(1,fabs(first)+fabs(second))?0:value;
}
static inline double zda_map_area(const ZdaMapping *map) {
    double area = 0;
    for (uint32_t i = 1; i+1 < map->count; ++i) area += zda_cross(map->polygon[0], map->polygon[i], map->polygon[i+1]);
    return area;
}
static inline BOOL zda_mapping_valid(const ZdaMapping *map) {
    if (map->reserved || map->count > ZDA_MAP_POINTS || (map->count && map->count < 3)) return FALSE;
    for (unsigned i = 0; i < 6; ++i) if (!isfinite(map->forward[i]) || !isfinite(map->inverse[i]) || fabs(map->forward[i]) > 1e12 || fabs(map->inverse[i]) > 1e12) return FALSE;
    const double *matrix=map->forward;
    const double scale=fmax(fmax(fabs(matrix[0]),fabs(matrix[1])),fmax(fabs(matrix[2]),fabs(matrix[3])));
    if(scale==0)return FALSE;
    const double a=matrix[0]/scale,b=matrix[2]/scale,c=matrix[1]/scale,d=matrix[3]/scale;
    const double determinant=a*d-b*c;
    if(determinant==0 || fmax(fabs(a)+fabs(b),fabs(c)+fabs(d))*fmax(fabs(d)+fabs(b),fabs(c)+fabs(a))/fabs(determinant)>1e12)return FALSE;
    const double factor=(1/scale)/determinant;
    double expected[6]={d*factor,-c*factor,-b*factor,a*factor,0,0};
    expected[4]=-(expected[0]*matrix[4]+expected[2]*matrix[5]);
    expected[5]=-(expected[1]*matrix[4]+expected[3]*matrix[5]);
    for (unsigned i = 0; i < 6; ++i) {
        if (!isfinite(expected[i]) || fabs(expected[i])>1e12 || fabs(map->inverse[i]-expected[i])>64*DBL_EPSILON*fmax(1,fabs(expected[i])))return FALSE;
    }
    for (uint32_t i = 0; i < map->count; ++i) if (!isfinite(map->polygon[i].x) || !isfinite(map->polygon[i].y) || fabs(map->polygon[i].x)>1e12 || fabs(map->polygon[i].y)>1e12) return FALSE;
    const double area = zda_map_area(map);
    if (map->count && (!isfinite(area) || area == 0)) return FALSE;
    /* Every point lies on the inner side of every edge; concave/unsorted or
       self-intersecting input is rejected before replacing any old source. */
    for (uint32_t i = 0; i < map->count; ++i) {
        const ZdaPoint first = map->polygon[i], last = map->polygon[(i+1)%map->count];
        if (first.x == last.x && first.y == last.y) return FALSE;
        for (uint32_t j = 0; j < map->count; ++j) {
            const double cross = zda_cross(first,last,map->polygon[j]);
            const double scale = fabs((last.x-first.x)*(map->polygon[j].y-first.y))+fabs((last.y-first.y)*(map->polygon[j].x-first.x));
            if (cross*(area>0?1:-1) < -1e-12*fmax(1,scale)) return FALSE;
        }
    }
    return TRUE;
}
static inline void zda_copy_mapping(ZdaNative *state, uint32_t source, ZdaMapped *out) {
    out->active = state->mappings && state->mapped[source];
    if (out->active) out->value = state->mappings[source];
}
static inline BOOL zda_mapping_contains(const ZdaMapping *value, ZdaPoint point) {
    if (!value->count) return FALSE;
    const double orientation = zda_map_area(value)>0 ? 1 : -1;
    for (uint32_t i=0;i<value->count;++i) if (zda_map_distance(value->polygon[i],value->polygon[(i+1)%value->count],point,orientation) < 0) return FALSE;
    return TRUE;
}
static inline BOOL zda_map_contains(const ZdaMapped *map, ZdaPoint point) {
    return !map->active || zda_mapping_contains(&map->value,point);
}
static inline BOOL zda_polygon_append(ZdaPolygon *polygon, ZdaPoint point) {
    if (polygon->count && polygon->points[polygon->count-1].x == point.x && polygon->points[polygon->count-1].y == point.y) return TRUE;
    if (polygon->count == ZDA_MAP_POINTS+4) return FALSE;
    polygon->points[polygon->count++] = point; return TRUE;
}
static inline BOOL zda_mapping_rectangle(const ZdaMapping *value, ZdaRect rect, ZdaRect *out) {
    if (rect.width<=0 || rect.height<=0) return FALSE;
    if (!value->count) return FALSE;
    ZdaPolygon current={.count=4}, scratch={0};
    current.points[0]=zda_map_point(value->forward,(ZdaPoint){rect.x,rect.y});
    current.points[1]=zda_map_point(value->forward,(ZdaPoint){rect.x+rect.width,rect.y});
    current.points[2]=zda_map_point(value->forward,(ZdaPoint){rect.x+rect.width,rect.y+rect.height});
    current.points[3]=zda_map_point(value->forward,(ZdaPoint){rect.x,rect.y+rect.height});
    const double orientation=zda_map_area(value)>0?1:-1;
    for (uint32_t i=0;i<value->count && current.count;++i) {
        const ZdaPoint a=value->polygon[i],b=value->polygon[(i+1)%value->count];
        scratch.count=0;
        ZdaPoint previous=current.points[current.count-1]; double before=zda_map_distance(a,b,previous,orientation);
        for (uint32_t j=0;j<current.count;++j) {
            const ZdaPoint point=current.points[j]; const double after=zda_map_distance(a,b,point,orientation);
            if ((before>=0)!=(after>=0)) {
                const double t=fmax(0,fmin(1,before/(before-after)));
                if (!zda_polygon_append(&scratch,(ZdaPoint){previous.x+(point.x-previous.x)*t,previous.y+(point.y-previous.y)*t})) return FALSE;
            }
            if (after>=0 && !zda_polygon_append(&scratch,point)) return FALSE;
            previous=point; before=after;
        }
        if (scratch.count>1 && scratch.points[0].x==scratch.points[scratch.count-1].x && scratch.points[0].y==scratch.points[scratch.count-1].y) --scratch.count;
        current=scratch;
    }
    if (current.count<3) return FALSE;
    double area=0; for(uint32_t i=1;i+1<current.count;++i) area+=zda_cross(current.points[0],current.points[i],current.points[i+1]);
    if (area==0) return FALSE;
    double left=current.points[0].x,right=left,top=current.points[0].y,bottom=top;
    for(uint32_t i=1;i<current.count;++i) {left=fmin(left,current.points[i].x);right=fmax(right,current.points[i].x);top=fmin(top,current.points[i].y);bottom=fmax(bottom,current.points[i].y);}
    *out=(ZdaRect){left,top,right-left,bottom-top}; return TRUE;
}
static inline BOOL zda_map_rectangle(const ZdaMapped *map, ZdaRect rect, ZdaRect *out) {
    if (rect.width<=0 || rect.height<=0) return FALSE;
    if (!map->active) { *out=rect; return TRUE; }
    return zda_mapping_rectangle(&map->value,rect,out);
}
/* Caller holds the native lock. Auxiliary nodes borrow this one common
   mapping; none of the per-node records or providers owns a matrix copy. */
static inline BOOL zda_auxiliary_rectangle(const ZdaAuxiliary *aux, const ZdaAuxGeometry *g, ZdaRect *out) {
    if(!(g->flags&4)||g->width<=0||g->height<=0)return FALSE;
    ZdaRect rect={g->x,g->y,g->width,g->height};
    if(aux->affine)return aux->affine->active&&zda_mapping_rectangle(&aux->affine->mapping,rect,out);
    *out=rect;return TRUE;
}
static inline BOOL zda_auxiliary_contains(const ZdaAuxiliary *aux, const ZdaAuxGeometry *g, ZdaPoint point) {
    if(!(g->flags&4)||g->width<=0||g->height<=0)return FALSE;
    if(aux->affine){
        if(!aux->affine->active||!zda_mapping_contains(&aux->affine->mapping,point))return FALSE;
        point=zda_map_point(aux->affine->mapping.inverse,point);
    }
    return point.x>=g->x&&point.y>=g->y&&point.x<g->x+g->width&&point.y<g->y+g->height;
}
static inline BOOL zda_map_caret(const ZdaMapped *map, ZdaRect rect) {
    if (!map->active) return TRUE;
    const ZdaMapping *value=&map->value;
    if (!value->count) return FALSE;
    const ZdaPoint first=zda_map_point(value->forward,(ZdaPoint){rect.x,rect.y}),last=zda_map_point(value->forward,(ZdaPoint){rect.x+rect.width,rect.y+rect.height});
    double start=0,end=1; const double orientation=zda_map_area(value)>0?1:-1;
    for(uint32_t i=0;i<value->count;++i) {
        const ZdaPoint a=value->polygon[i],b=value->polygon[(i+1)%value->count];
        const double before=zda_map_distance(a,b,first,orientation),after=zda_map_distance(a,b,last,orientation);
        if(before<0 && after<0) return FALSE;
        if((before<0)!=(after<0)) {const double t=fmax(0,fmin(1,before/(before-after)));if(before<0) start=fmax(start,t);else end=fmin(end,t);if(start>end)return FALSE;}
    }
    return TRUE;
}
#endif
