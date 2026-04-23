insert into public.screening_list_entry (
    id,
    list_id,
    entry_type,
    full_name,
    country,
    tax_id,
    tax_id_normalized
)
values (
    uuid_generate_v4(),
    '33c1a0ee-fd04-43ed-ba77-25106ef14669',
    'PERSON',
    'Juan Perez',
    'AR',
    '20-12345678-9',
    public.normalize_tax_id('20-12345678-9')
);