#ifndef ZIGGURAT_TEXT_LAYOUT_OUTLINE_LINUX_H
#define ZIGGURAT_TEXT_LAYOUT_OUTLINE_LINUX_H
#include <math.h>
/* Pango keeps the original shaped runs. Cairo's temporary path storage is
   opaque native preparation cost, not a caller-owned pixel plane. */
_Static_assert(sizeof(ZtlOutlineSegment)==28,"outline segment ABI");
_Static_assert(sizeof(ZtlGlyphCell)==32,"glyph cell ABI");
static int outline_cells(Layout *layout,ZtlGlyphCell *cells,uint32_t capacity,uint32_t *count){
    if(!capacity)return ZTL_OK;
#if PANGO_VERSION_CHECK(1,50,0)
    PangoLayoutIter *iter=pango_layout_get_iter(layout->layout);
    if(!iter)return ZTL_OOM;
    int result=ZTL_OK;
    do{
        PangoLayoutRun *run=pango_layout_iter_get_run_readonly(iter);
        if(!run)continue;
        const uint32_t length=(uint32_t)run->glyphs->num_glyphs;
        if(length>capacity-*count){result=ZTL_CAPACITY;break;}
        if(cells&&length){
            PangoFont *font=run->item->analysis.font;
            if(!font){result=ZTL_UNSUPPORTED_OUTLINE;break;}
            PangoFontMetrics *metrics=pango_font_get_metrics(font,run->item->analysis.language);
            if(!metrics){result=ZTL_OOM;break;}
            const double ascent=(double)pango_font_metrics_get_ascent(metrics)/PANGO_SCALE;
            const double descent=(double)pango_font_metrics_get_descent(metrics)/PANGO_SCALE;
            pango_font_metrics_unref(metrics);
            PangoRectangle positioned,local;
            pango_layout_iter_get_run_extents(iter,NULL,&positioned);
            pango_glyph_string_extents(run->glyphs,font,NULL,&local);
            double pen=((double)positioned.x-local.x)/PANGO_SCALE;
            const double baseline=(double)pango_layout_iter_get_run_baseline(iter)/PANGO_SCALE;
            for(uint32_t i=0;i<length;i++){
                const PangoGlyphGeometry geometry=run->glyphs->glyphs[i].geometry;
                const double advance=(double)geometry.width/PANGO_SCALE;
                const double first=pen+(double)geometry.x_offset/PANGO_SCALE,last=first+advance;
                cells[*count+i]=(ZtlGlyphCell){first<last?first:last,baseline+(double)geometry.y_offset/PANGO_SCALE-ascent,advance<0?-advance:advance,ascent+descent};
                pen+=advance;
            }
        }
        *count+=length;
    }while(pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);return result;
#else
    (void)layout;(void)cells;(void)count;return ZTL_UNSUPPORTED_OUTLINE;
#endif
}
int ztl_outline(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlGlyphCell *cells,uint32_t cell_capacity,uint32_t *cell_count,ZtlError *error){
    Layout *layout=storage;*error=(ZtlError){0};*count=0;*cell_count=0;
    const int cell_result=outline_cells(layout,cells,cell_capacity,cell_count);
    if(cell_result!=ZTL_OK)return cell_result;
    cairo_surface_t *surface=cairo_recording_surface_create(CAIRO_CONTENT_ALPHA,NULL);
    cairo_t *context=cairo_create(surface);cairo_path_t *path=NULL;int result=ZTL_OK;
    cairo_status_t status=cairo_status(context);
    if(status!=CAIRO_STATUS_SUCCESS)goto failed;
    cairo_move_to(context,0,0);pango_cairo_layout_path(context,layout->layout);
    status=cairo_status(context);if(status!=CAIRO_STATUS_SUCCESS)goto failed;
    path=cairo_copy_path(context);status=path->status;if(status!=CAIRO_STATUS_SUCCESS)goto failed;
    uint32_t needed=0;
    for(int at=0;at<path->num_data;at+=path->data[at].header.length){
        if(needed==capacity){result=ZTL_CAPACITY;goto done;}
        needed++;
    }
    if(output){
        uint32_t index=0;
        for(int at=0;at<path->num_data;at+=path->data[at].header.length){
            const cairo_path_data_t *data=&path->data[at];ZtlOutlineSegment segment={0};
            switch(data->header.type){
                case CAIRO_PATH_MOVE_TO:segment.kind=ZTL_OUTLINE_MOVE;break;
                case CAIRO_PATH_LINE_TO:segment.kind=ZTL_OUTLINE_LINE;break;
                case CAIRO_PATH_CURVE_TO:segment.kind=ZTL_OUTLINE_CUBIC;break;
                case CAIRO_PATH_CLOSE_PATH:segment.kind=ZTL_OUTLINE_CLOSE;break;
                default:result=ZTL_UNSUPPORTED_OUTLINE;goto done;
            }
            const unsigned points=segment.kind==ZTL_OUTLINE_CUBIC?3:segment.kind==ZTL_OUTLINE_CLOSE?0:1;
            for(unsigned i=0;i<points;i++)segment.points[i]=(ZtlOutlinePoint){(float)data[i+1].point.x,(float)data[i+1].point.y};
            output[index++]=segment;
        }
    }
    *count=needed;goto done;
failed:
    *error=(ZtlError){3,(int32_t)status};result=status==CAIRO_STATUS_NO_MEMORY?ZTL_OOM:ZTL_FAILED;
done:
    if(path)cairo_path_destroy(path);cairo_destroy(context);cairo_surface_destroy(surface);return result;
}
_Static_assert(sizeof(ZtlOutlineGlyph)==96,"mapped glyph ABI");
_Static_assert(sizeof(ZtlOutlineCluster)==32,"mapped cluster ABI");
static int mapping_charge(ZtlOutlineMapping *map,uint64_t work){
    if(map->cancellation&&__atomic_load_n(map->cancellation,__ATOMIC_ACQUIRE))return ZTL_OUTLINE_CANCELLED;
    if(work>map->work_limit-map->work)return ZTL_OUTLINE_WORK;
    map->work+=work;return ZTL_OK;
}
static int mapping_path(cairo_t *context,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *map,ZtlError *error){
    cairo_path_t *path=cairo_copy_path(context);
    if(path->status!=CAIRO_STATUS_SUCCESS){*error=(ZtlError){3,(int32_t)path->status};int result=path->status==CAIRO_STATUS_NO_MEMORY?ZTL_OOM:ZTL_FAILED;cairo_path_destroy(path);return result;}
    int result=ZTL_OK;
    for(int at=0;at<path->num_data;at+=path->data[at].header.length){
        result=mapping_charge(map,1);if(result!=ZTL_OK)break;
        if(*count==capacity){result=ZTL_CAPACITY;break;}
        const cairo_path_data_t *data=&path->data[at];ZtlOutlineSegment segment={0};
        switch(data->header.type){
            case CAIRO_PATH_MOVE_TO:segment.kind=ZTL_OUTLINE_MOVE;break;
            case CAIRO_PATH_LINE_TO:segment.kind=ZTL_OUTLINE_LINE;break;
            case CAIRO_PATH_CURVE_TO:segment.kind=ZTL_OUTLINE_CUBIC;break;
            case CAIRO_PATH_CLOSE_PATH:segment.kind=ZTL_OUTLINE_CLOSE;break;
            default:result=ZTL_UNSUPPORTED_MAPPING;goto done;
        }
        const unsigned points=segment.kind==ZTL_OUTLINE_CUBIC?3:segment.kind==ZTL_OUTLINE_CLOSE?0:1;
        for(unsigned i=0;i<points;i++)segment.points[i]=(ZtlOutlinePoint){(float)data[i+1].point.x,(float)data[i+1].point.y};
        if(output)output[*count]=segment;++*count;
    }
done:cairo_path_destroy(path);return result;
}
int ztl_outline_mapping(void *storage,ZtlOutlineSegment *output,uint32_t capacity,uint32_t *count,ZtlOutlineMapping *map,ZtlError *error){
    *error=(ZtlError){0};*count=0;map->glyph_count=map->cluster_count=map->run_count=0;map->work=0;
#if PANGO_VERSION_CHECK(1,50,0)
    Layout *layout=storage;const char *text=pango_layout_get_text(layout->layout);
    PangoLayoutIter *iter=pango_layout_get_iter(layout->layout);if(!iter)return ZTL_OOM;
    cairo_surface_t *surface=cairo_recording_surface_create(CAIRO_CONTENT_ALPHA,NULL);
    cairo_t *context=cairo_create(surface);int result=ZTL_OK;
    if(cairo_status(context)!=CAIRO_STATUS_SUCCESS){result=ZTL_OOM;goto done;}
    do{
        result=mapping_charge(map,1);if(result!=ZTL_OK)break;
        PangoLayoutRun *run=pango_layout_iter_get_run_readonly(iter);if(!run)continue;
        if(run->glyphs->num_glyphs<0||run->item->offset<0||run->item->length<0||
           (uint32_t)run->item->offset>layout->length||(uint32_t)run->item->length>layout->length-(uint32_t)run->item->offset||!run->item->analysis.font){result=ZTL_UNSUPPORTED_MAPPING;break;}
        const uint32_t glyph_count=(uint32_t)run->glyphs->num_glyphs;
        if(glyph_count>map->glyph_capacity-map->glyph_count){result=ZTL_CAPACITY;break;}
        PangoFontMetrics *metrics=pango_font_get_metrics(run->item->analysis.font,run->item->analysis.language);
        if(!metrics){result=ZTL_OOM;break;}
        const double ascent=(double)pango_font_metrics_get_ascent(metrics)/PANGO_SCALE,descent=(double)pango_font_metrics_get_descent(metrics)/PANGO_SCALE;
        pango_font_metrics_unref(metrics);
        PangoRectangle positioned,local;pango_layout_iter_get_run_extents(iter,NULL,&positioned);pango_glyph_string_extents(run->glyphs,run->item->analysis.font,NULL,&local);
        int64_t pen=(int64_t)positioned.x-local.x;
        const double baseline=(double)pango_layout_iter_get_run_baseline(iter)/PANGO_SCALE;
        const uint32_t run_index=map->run_count++,level=run->item->analysis.level;const gboolean rtl=level&1;
        PangoGlyphItemIter cluster;uint32_t physical=0;
        for(gboolean have=rtl?pango_glyph_item_iter_init_end(&cluster,run,text):pango_glyph_item_iter_init_start(&cluster,run,text);have;have=rtl?pango_glyph_item_iter_prev_cluster(&cluster):pango_glyph_item_iter_next_cluster(&cluster)){
            result=mapping_charge(map,1);if(result!=ZTL_OK)goto done;
            const int lo=rtl?cluster.end_glyph+1:cluster.start_glyph,hi=rtl?cluster.start_glyph+1:cluster.end_glyph;
            if(lo<0||hi<=lo||(uint32_t)lo!=physical||(uint32_t)hi>glyph_count||cluster.start_index<run->item->offset||cluster.end_index<cluster.start_index||cluster.end_index>run->item->offset+run->item->length){result=ZTL_UNSUPPORTED_MAPPING;goto done;}
            if(map->cluster_count==map->cluster_capacity){result=ZTL_CAPACITY;goto done;}
            const uint32_t cluster_index=map->cluster_count++,glyph_start=map->glyph_count,segment_start=*count;
            for(int i=lo;i<hi;i++){
                result=mapping_charge(map,2);if(result!=ZTL_OK)goto done;
                const PangoGlyphInfo info=run->glyphs->glyphs[i];
                const double x=(double)pen/PANGO_SCALE,advance=(double)info.geometry.width/PANGO_SCALE;
                const double origin=x+(double)info.geometry.x_offset/PANGO_SCALE,origin_y=baseline+(double)info.geometry.y_offset/PANGO_SCALE;
                const uint32_t begin=*count;
                // This is the original glyph and geometry, not a new shaping
                // request. Pango stores the run's glyph array in visual order.
                PangoGlyphString one={0};one.num_glyphs=1;one.glyphs=(PangoGlyphInfo *)&info;one.log_clusters=run->glyphs->log_clusters+i;
                cairo_new_path(context);cairo_move_to(context,x,baseline);pango_cairo_glyph_string_path(context,run->item->analysis.font,&one);
                result=mapping_path(context,output,capacity,count,map,error);if(result!=ZTL_OK)goto done;
                if(map->glyphs)map->glyphs[map->glyph_count]=(ZtlOutlineGlyph){info.glyph,cluster_index,run_index,level,{begin,*count-begin},{x,baseline},{origin,origin_y},advance,{fmin(origin,origin+advance),origin_y-ascent,fabs(advance),ascent+descent}};
                ++map->glyph_count;pen+=info.geometry.width;
            }
            if(map->clusters)map->clusters[cluster_index]=(ZtlOutlineCluster){{(uint32_t)cluster.start_index,(uint32_t)cluster.end_index},{glyph_start,map->glyph_count-glyph_start},{segment_start,*count-segment_start},run_index,level};
            physical=(uint32_t)hi;
        }
        if(physical!=glyph_count){result=ZTL_UNSUPPORTED_MAPPING;break;}
    }while(pango_layout_iter_next_run(iter));
done:cairo_destroy(context);cairo_surface_destroy(surface);pango_layout_iter_free(iter);return result;
#else
    (void)storage;(void)output;(void)capacity;return ZTL_UNSUPPORTED_MAPPING;
#endif
}
#endif
