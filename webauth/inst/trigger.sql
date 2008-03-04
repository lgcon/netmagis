-- $Id: trigger.sql,v 1.3 2008-03-04 21:04:42 pda Exp $

CREATE FUNCTION ajouter_soundex () RETURNS TRIGGER AS '
    BEGIN
	NEW.phnom    := SOUNDEX (NEW.nom) ;
	NEW.phprenom := SOUNDEX (NEW.prenom) ;
	RETURN NEW ;
    END ;
    ' LANGUAGE 'plpgsql' ;

CREATE TRIGGER phnom
    BEFORE INSERT OR UPDATE
    ON utilisateurs
    FOR EACH ROW
    EXECUTE PROCEDURE ajouter_soundex ()
    ;