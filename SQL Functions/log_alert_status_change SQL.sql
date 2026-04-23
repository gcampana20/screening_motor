CREATE OR REPLACE FUNCTION public.fn_log_alert_status_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO public.alert_status_history (
            id,
            created_at,
            updated_at,
            type,
            alert_id,
            prev_status,
            new_status,
            valid_from,
            valid_to
        )
        VALUES (
            uuid_generate_v4(),
            now(),
            now(),
            'STATUS_CHANGE',
            OLD.id,
            OLD.status,
            NEW.status,
            now(),
            NULL
        );
    END IF;

    RETURN NEW;
END;
$$;