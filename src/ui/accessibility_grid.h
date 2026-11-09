/* Tables, grids and tree grids have UI Automation's Grid and Table patterns,
   and their cells and headers GridItem and TableItem, so that Narrator reads
   a cell's place, "row 4,121 of 10,000". Places count from 0 among all the
   rows and columns, built or not: as the application gave them
   (row_index, column_index, from 1), else as a list's rows say which of all
   they are (position) after the header rows above them, else by the rows
   and cells built. Each cell covers one row and one column. Places are
   found as a client asks, so publishing pays nothing. Included by
   accessibility.c; every helper here is called with the state's lock held
   unless it says otherwise. */
#ifndef ZUA_GRID_H
#define ZUA_GRID_H

typedef struct GridPlace { uint32_t index, at; } GridPlace;

/* The row, grid or cell nearest above a node, which owns it: a row's grid,
   a cell's row (or its grid, for a cell outside rows). */
static const Node *grid_owner_locked(State *s, const Node *n) {
    const Node *up = find(s, n->parent);
    for (uint32_t depth = 0; up && up->id != 0 && depth < NODE_CAP; ++depth) {
        if (tabular_role(up->role) || grid_row_role(up->role) || cell_role(up->role)) return up;
        up = find(s, up->parent);
    }
    return NULL;
}
/* The rows of a grid in order with their places, leaving out those of
   grids inside it, and how many header rows come before the first that
   says which of all it is. */
static uint32_t grid_rows_locked(State *s, const Node *grid, GridPlace *rows, uint32_t *heads) {
    uint32_t count = 0; BOOL listed = FALSE; *heads = 0;
    for (uint32_t i = 1; i < s->count; ++i) {
        const Node *n = &s->nodes[i];
        if (!grid_row_role(n->role) || grid_owner_locked(s, n) != grid) continue;
        uint32_t at = count;
        if (n->row_index > 0) at = n->row_index - 1;
        else if (n->position > 0) { at = *heads + n->position - 1; listed = TRUE; }
        else if (!listed) ++*heads;
        rows[count++] = (GridPlace){ i, at };
    }
    return count;
}
/* The cells of a row in order with their columns: a cell without one of
   its own is in the column after the cell before it. */
static uint32_t grid_cells_locked(State *s, const Node *row, GridPlace *cells) {
    uint32_t count = 0, column = 0;
    for (uint32_t i = 1; i < s->count; ++i) {
        const Node *n = &s->nodes[i];
        if (!cell_role(n->role) || grid_owner_locked(s, n) != row) continue;
        if (n->column_index > 0) column = n->column_index - 1;
        cells[count++] = (GridPlace){ i, column };
        ++column;
    }
    return count;
}
/* How many rows a grid has: as the application gave it, else as its list
   says (set_size) with the header rows, else those built. */
static uint32_t grid_row_count_locked(State *s, const Node *grid) {
    if (grid->row_count) return grid->row_count;
    GridPlace rows[NODE_CAP]; uint32_t heads;
    const uint32_t count = grid_rows_locked(s, grid, rows, &heads);
    uint32_t total = grid->set_size ? heads + grid->set_size : 0;
    for (uint32_t i = 0; i < count; ++i) if (rows[i].at + 1 > total) total = rows[i].at + 1;
    return total;
}
/* How many columns a grid has: as the application gave it, else those of
   its rows' cells. */
static uint32_t grid_column_count_locked(State *s, const Node *grid) {
    if (grid->column_count) return grid->column_count;
    GridPlace rows[NODE_CAP], cells[NODE_CAP]; uint32_t heads, total = 0;
    const uint32_t count = grid_rows_locked(s, grid, rows, &heads);
    for (uint32_t r = 0; r < count; ++r) {
        const uint32_t built = grid_cells_locked(s, &s->nodes[rows[r].index], cells);
        for (uint32_t c = 0; c < built; ++c) if (cells[c].at + 1 > total) total = cells[c].at + 1;
    }
    return total;
}
/* The row and the column of a cell in its grid. */
static void grid_place_locked(State *s, const Node *cell, uint32_t *row, uint32_t *column) {
    *row = 0; *column = 0;
    const Node *owner = grid_owner_locked(s, cell);
    const Node *grid = grid_of_locked(s, cell);
    if (owner && grid && grid_row_role(owner->role)) {
        GridPlace places[NODE_CAP]; uint32_t heads;
        uint32_t count = grid_rows_locked(s, grid, places, &heads);
        for (uint32_t i = 0; i < count; ++i) if (&s->nodes[places[i].index] == owner) *row = places[i].at;
        count = grid_cells_locked(s, owner, places);
        for (uint32_t i = 0; i < count; ++i) if (&s->nodes[places[i].index] == cell) *column = places[i].at;
    } else if (cell->column_index > 0) *column = cell->column_index - 1;
    if (cell->row_index > 0) *row = cell->row_index - 1;
}
/* The cells of a grid, row by row, with the row and the column of each;
   role 0 takes every cell, else cells of that role alone. */
static uint32_t grid_all_cells_locked(State *s, const Node *grid, uint32_t role, GridPlace *cells, uint32_t *rows_of) {
    GridPlace rows[NODE_CAP], built[NODE_CAP]; uint32_t heads, total = 0;
    const uint32_t count = grid_rows_locked(s, grid, rows, &heads);
    for (uint32_t r = 0; r < count; ++r) {
        const uint32_t n = grid_cells_locked(s, &s->nodes[rows[r].index], built);
        for (uint32_t c = 0; c < n && total < NODE_CAP; ++c) {
            const Node *cell = &s->nodes[built[c].index];
            if (role && cell->role != role) continue;
            rows_of[total] = cell->row_index > 0 ? cell->row_index - 1 : rows[r].at;
            cells[total++] = built[c];
        }
    }
    return total;
}

/* SAFEARRAY of the providers of nodes, by id; called without the lock. */
static HRESULT provider_array(State *s, const uint64_t *ids, uint32_t count, SAFEARRAY **out) {
    *out = NULL;
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, count); if (!array) return E_OUTOFMEMORY;
    for (LONG i = 0; i < (LONG)count; ++i) {
        Provider *item = NULL; HRESULT hr = provider_new(s, ids[i], &item);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
        hr = SafeArrayPutElement(array, &i, &item->simple); provider_release(item);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array; return S_OK;
}
static HRESULT provider_out(State *s, BOOL found, uint64_t id, IRawElementProviderSimple **out) {
    if (!found) return S_OK;
    Provider *p = NULL; HRESULT hr = provider_new(s, id, &p);
    if (SUCCEEDED(hr)) *out = &p->simple;
    return hr;
}

PROVIDER_UNKNOWN(grid, IGridProvider, grid)
PROVIDER_UNKNOWN(grid_item, IGridItemProvider, grid_item)
PROVIDER_UNKNOWN(table, ITableProvider, table)
PROVIDER_UNKNOWN(table_item, ITableItemProvider, table_item)

static HRESULT STDMETHODCALLTYPE grid_get_item(IGridProvider *iface, int row, int column, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL;
    Provider *p = grid_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (!n) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    if (row < 0 || column < 0 || (uint32_t)row >= grid_row_count_locked(s, n) || (uint32_t)column >= grid_column_count_locked(s, n)) {
        ReleaseSRWLockShared(&s->lock); return E_INVALIDARG;
    }
    GridPlace cells[NODE_CAP]; uint32_t rows[NODE_CAP];
    const uint32_t count = grid_all_cells_locked(s, n, 0, cells, rows);
    BOOL found = FALSE; uint64_t id = 0;
    for (uint32_t i = 0; i < count && !found; ++i) if (rows[i] == (uint32_t)row && cells[i].at == (uint32_t)column) { id = s->nodes[cells[i].index].id; found = TRUE; }
    ReleaseSRWLockShared(&s->lock);
    /* A cell not built, as in a row out of view, is none. */
    return provider_out(s, found, id, out);
}
static HRESULT grid_count(Provider *p, int *out, BOOL rows) {
    if (!out) return E_POINTER; *out = 0; State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (n) *out = (int)(rows ? grid_row_count_locked(s, n) : grid_column_count_locked(s, n));
    ReleaseSRWLockShared(&s->lock);
    return n ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE grid_rows(IGridProvider *iface, int *out) { return grid_count(grid_self(iface), out, TRUE); }
static HRESULT STDMETHODCALLTYPE grid_columns(IGridProvider *iface, int *out) { return grid_count(grid_self(iface), out, FALSE); }

static HRESULT grid_item_place(Provider *p, int *out, int field) {
    if (!out) return E_POINTER; *out = 0; State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (n) {
        uint32_t row, column; grid_place_locked(s, n, &row, &column);
        *out = field == 0 ? (int)row : field == 1 ? (int)column : 1;
    }
    ReleaseSRWLockShared(&s->lock);
    return n ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}
static HRESULT STDMETHODCALLTYPE grid_item_row(IGridItemProvider *iface, int *out) { return grid_item_place(grid_item_self(iface), out, 0); }
static HRESULT STDMETHODCALLTYPE grid_item_column(IGridItemProvider *iface, int *out) { return grid_item_place(grid_item_self(iface), out, 1); }
static HRESULT STDMETHODCALLTYPE grid_item_row_span(IGridItemProvider *iface, int *out) { return grid_item_place(grid_item_self(iface), out, 2); }
static HRESULT STDMETHODCALLTYPE grid_item_column_span(IGridItemProvider *iface, int *out) { return grid_item_place(grid_item_self(iface), out, 3); }
static HRESULT STDMETHODCALLTYPE grid_item_grid(IGridItemProvider *iface, IRawElementProviderSimple **out) {
    if (!out) return E_POINTER; *out = NULL;
    Provider *p = grid_item_self(iface); State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    const Node *grid = n ? grid_of_locked(s, n) : NULL;
    const uint64_t id = grid ? grid->id : 0;
    ReleaseSRWLockShared(&s->lock);
    return n ? provider_out(s, grid != NULL, id, out) : UIA_E_ELEMENTNOTAVAILABLE;
}

/* The headers of a grid of a role: those over one column, or beside one
   row, alone when `line` is not negative. */
static HRESULT grid_headers(State *s, const Node *grid, uint32_t role, int line, SAFEARRAY **out) {
    GridPlace cells[NODE_CAP]; uint32_t rows[NODE_CAP]; uint64_t ids[NODE_CAP]; uint32_t count = 0;
    const uint32_t total = grid ? grid_all_cells_locked(s, grid, role, cells, rows) : 0;
    for (uint32_t i = 0; i < total; ++i) {
        const uint32_t at = role == ROLE_COLUMN_HEADER ? cells[i].at : rows[i];
        if (line < 0 || at == (uint32_t)line) ids[count++] = s->nodes[cells[i].index].id;
    }
    ReleaseSRWLockShared(&s->lock);
    return provider_array(s, ids, count, out);
}
static HRESULT table_headers(Provider *p, uint32_t role, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (!n) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    return grid_headers(s, n, role, -1, out);
}
static HRESULT STDMETHODCALLTYPE table_row_headers(ITableProvider *iface, SAFEARRAY **out) { return table_headers(table_self(iface), ROLE_ROW_HEADER, out); }
static HRESULT STDMETHODCALLTYPE table_column_headers(ITableProvider *iface, SAFEARRAY **out) { return table_headers(table_self(iface), ROLE_COLUMN_HEADER, out); }
static HRESULT STDMETHODCALLTYPE table_major(ITableProvider *iface, enum RowOrColumnMajor *out) {
    if (!out) return E_POINTER; Provider *p = table_self(iface); Node n;
    HRESULT hr = read_provider_node(p, &n); if (SUCCEEDED(hr)) *out = RowOrColumnMajor_RowMajor; return hr;
}
/* The row headers beside a cell, or the column headers over it; none for
   a header of that kind itself. */
static HRESULT table_item_headers(Provider *p, uint32_t role, SAFEARRAY **out) {
    if (!out) return E_POINTER; *out = NULL; State *s = p->state;
    AcquireSRWLockShared(&s->lock); Node *n = provider_find_locked(p);
    if (!n) { ReleaseSRWLockShared(&s->lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    const Node *grid = n->role == role ? NULL : grid_of_locked(s, n);
    uint32_t row, column; grid_place_locked(s, n, &row, &column);
    return grid_headers(s, grid, role, (int)(role == ROLE_COLUMN_HEADER ? column : row), out);
}
static HRESULT STDMETHODCALLTYPE table_item_row_headers(ITableItemProvider *iface, SAFEARRAY **out) { return table_item_headers(table_item_self(iface), ROLE_ROW_HEADER, out); }
static HRESULT STDMETHODCALLTYPE table_item_column_headers(ITableItemProvider *iface, SAFEARRAY **out) { return table_item_headers(table_item_self(iface), ROLE_COLUMN_HEADER, out); }

static const IGridProviderVtbl grid_vtable = {
    .QueryInterface = grid_query, .AddRef = grid_add, .Release = grid_release,
    .GetItem = grid_get_item, .get_RowCount = grid_rows, .get_ColumnCount = grid_columns,
};
static const IGridItemProviderVtbl grid_item_vtable = {
    .QueryInterface = grid_item_query, .AddRef = grid_item_add, .Release = grid_item_release,
    .get_Row = grid_item_row, .get_Column = grid_item_column, .get_RowSpan = grid_item_row_span,
    .get_ColumnSpan = grid_item_column_span, .get_ContainingGrid = grid_item_grid,
};
static const ITableProviderVtbl table_vtable = {
    .QueryInterface = table_query, .AddRef = table_add, .Release = table_release,
    .GetRowHeaders = table_row_headers, .GetColumnHeaders = table_column_headers, .get_RowOrColumnMajor = table_major,
};
static const ITableItemProviderVtbl table_item_vtable = {
    .QueryInterface = table_item_query, .AddRef = table_item_add, .Release = table_item_release,
    .GetRowHeaderItems = table_item_row_headers, .GetColumnHeaderItems = table_item_column_headers,
};
#endif
