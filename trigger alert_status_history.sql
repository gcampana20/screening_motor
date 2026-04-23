CREATE TRIGGER trg_alert_status_history
AFTER UPDATE OF status ON public.alert
FOR EACH ROW
EXECUTE FUNCTION public.fn_log_alert_status_change();