insert into public.person (
    id,
    created_at,
    updated_at,
	tenant_id,
    first_name,
	last_name,
    birth_date,
    tax_id,
    nacionality
)
values (
    uuid_generate_v4(),
    now(),
    now(),
    '5f12945c-a812-424e-887b-56f6d42cf3b7',
    'juan',
	'perez',
	'1980-05-20',
    '20-12345678-9',
	'Argentina'
);