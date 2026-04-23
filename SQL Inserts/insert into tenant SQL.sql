insert into public.tenant (
    id,
    created_at,
    updated_at,
	name
)
values (
    uuid_generate_v4(),
    now(),
    now(),
    'Juan Pérez'
)
;