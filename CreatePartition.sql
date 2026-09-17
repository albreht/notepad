/*
    usp_AddPartitionBoundaryIfNotExists

    Cel:
    - sprawdza, jaka funkcja i schemat partycjonowania są przypisane do danej tabeli,
    - wyświetla aktualne granice partycji (boundary values),
    - sprawdza, czy podana wartość numeryczna (np. 20200101 jako NUMERIC(8,0),
      reprezentująca datę w formacie YYYYMMDD) już istnieje jako granica,
    - jeśli nie istnieje - dodaje ją poprzez SPLIT RANGE.

    UWAGA (ważne, żeby nie zablokować produkcji):
    - SPLIT RANGE na partycji, w której już są dane, powoduje fizyczne
      przenoszenie wierszy i może być kosztowne / blokujące.
      Najlepsza praktyka: dodawać nowe granice "z wyprzedzeniem", zanim
      partycja docelowa zacznie przyjmować dane (czyli dzielona partycja
      powinna być pusta).
    - Procedura zakłada, że funkcja partycjonująca oparta jest o typ
      numeric/decimal (np. NUMERIC(8,0)).
    - Procedura bierze pierwszy indeks (heap albo clustered) tabeli jako
      źródło informacji o partycjonowaniu - tak jak to zwykle bywa
      skonfigurowane.

    Przykład użycia:
        EXEC dbo.usp_AddPartitionBoundaryIfNotExists
             @SchemaName    = 'dbo',
             @TableName     = 'Faktury',
             @BoundaryValue = 20200101;

        -- z jawnym wskazaniem filegroup dla nowej partycji:
        EXEC dbo.usp_AddPartitionBoundaryIfNotExists
             @SchemaName    = 'dbo',
             @TableName     = 'Faktury',
             @BoundaryValue = 20200101,
             @FileGroupName = 'FG_2020';
*/

CREATE OR ALTER PROCEDURE dbo.usp_AddPartitionBoundaryIfNotExists
    @SchemaName     SYSNAME,
    @TableName      SYSNAME,
    @BoundaryValue  NUMERIC(8,0),
    @FileGroupName  SYSNAME = NULL,   -- NULL = użyj tego samego filegroup co ostatnia partycja
    @WhatIf         BIT = 0           -- 1 = tylko pokaż co by się stało, nic nie zmieniaj
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @FullTableName          NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    DECLARE @ObjectId               INT = OBJECT_ID(@FullTableName);
    DECLARE @PartitionFunctionName  SYSNAME;
    DECLARE @PartitionSchemeName    SYSNAME;
    DECLARE @FunctionId             INT;
    DECLARE @ParamType              SYSNAME;
    DECLARE @LastFileGroup          SYSNAME;
    DECLARE @SQL                    NVARCHAR(MAX);

    ----------------------------------------------------------------------
    -- 1. Walidacja tabeli
    ----------------------------------------------------------------------
    IF @ObjectId IS NULL
    BEGIN
        RAISERROR(N'Tabela %s nie istnieje.', 16, 1, @FullTableName);
        RETURN;
    END

    ----------------------------------------------------------------------
    -- 2. Znajdź schemat i funkcję partycjonowania przypisaną do tabeli
    ----------------------------------------------------------------------
    SELECT TOP 1
        @PartitionSchemeName   = ps.name,
        @PartitionFunctionName = pf.name,
        @FunctionId            = pf.function_id
    FROM sys.indexes i
    JOIN sys.partition_schemes   ps ON i.data_space_id = ps.data_space_id
    JOIN sys.partition_functions pf ON ps.function_id  = pf.function_id
    WHERE i.object_id = @ObjectId
      AND i.index_id IN (0, 1);   -- 0 = heap, 1 = clustered index

    IF @PartitionFunctionName IS NULL
    BEGIN
        RAISERROR(N'Tabela %s nie jest partycjonowana (brak partition scheme/function).', 16, 1, @FullTableName);
        RETURN;
    END

    ----------------------------------------------------------------------
    -- 3. Sprawdź, czy funkcja partycjonująca jest oparta o typ numeric/decimal
    ----------------------------------------------------------------------
    SELECT @ParamType = t.name
    FROM sys.partition_functions pf
    JOIN sys.partition_parameters pp
         ON pf.function_id = pp.function_id
    JOIN sys.types t
         ON pp.system_type_id = t.system_type_id
        AND pp.user_type_id   = t.user_type_id
    WHERE pf.function_id = @FunctionId;

    IF @ParamType NOT IN ('numeric', 'decimal')
    BEGIN
        RAISERROR(N'Funkcja partycjonująca %s nie jest oparta o typ numeric/decimal (typ parametru: %s).',
                   16, 1, @PartitionFunctionName, @ParamType);
        RETURN;
    END

    ----------------------------------------------------------------------
    -- 4. Pokaż aktualny stan partycji (informacyjnie)
    ----------------------------------------------------------------------
    PRINT N'Tabela:              ' + @FullTableName;
    PRINT N'Partition function:  ' + @PartitionFunctionName;
    PRINT N'Partition scheme:    ' + @PartitionSchemeName;
    PRINT N'Aktualne granice partycji:';

    SELECT
        p.partition_number,
        prv.value                                   AS boundary_value,
        fg.name                                      AS filegroup_name,
        SUM(ps_.row_count)                           AS approx_row_count
    FROM sys.partitions p
    JOIN sys.indexes ix
         ON p.object_id = ix.object_id AND p.index_id = ix.index_id
    LEFT JOIN sys.partition_range_values prv
         ON prv.function_id = @FunctionId
        AND prv.boundary_id = p.partition_number
    LEFT JOIN sys.destination_data_spaces dds
         ON dds.partition_scheme_id = (SELECT data_space_id FROM sys.partition_schemes WHERE name = @PartitionSchemeName)
        AND dds.destination_id = p.partition_number
    LEFT JOIN sys.filegroups fg
         ON fg.data_space_id = dds.data_space_id
    LEFT JOIN sys.dm_db_partition_stats ps_
         ON ps_.object_id = p.object_id AND ps_.partition_id = p.partition_id AND ps_.index_id IN (0,1)
    WHERE p.object_id = @ObjectId
      AND ix.index_id IN (0, 1)
    GROUP BY p.partition_number, prv.value, fg.name
    ORDER BY p.partition_number;

    ----------------------------------------------------------------------
    -- 5. Sprawdź, czy podana wartość graniczna już istnieje
    ----------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM sys.partition_range_values prv
        WHERE prv.function_id = @FunctionId
          AND CONVERT(NUMERIC(8,0), prv.value) = @BoundaryValue
    )
    BEGIN
        PRINT N'Granica partycji dla wartości "' + CONVERT(VARCHAR(20), @BoundaryValue) + N'" już istnieje. Nic nie zmieniam.';
        RETURN;
    END

    PRINT N'Granica partycji dla wartości "' + CONVERT(VARCHAR(20), @BoundaryValue) + N'" NIE istnieje - zostanie utworzona.';

    ----------------------------------------------------------------------
    -- 6. Ustal filegroup dla NEXT USED (jeśli nie podano jawnie)
    ----------------------------------------------------------------------
    IF @FileGroupName IS NULL
    BEGIN
        SELECT TOP 1 @LastFileGroup = fg.name
        FROM sys.partition_schemes ps
        JOIN sys.destination_data_spaces dds ON ps.data_space_id = dds.partition_scheme_id
        JOIN sys.filegroups fg ON dds.data_space_id = fg.data_space_id
        WHERE ps.name = @PartitionSchemeName
        ORDER BY dds.destination_id DESC;

        SET @FileGroupName = ISNULL(@LastFileGroup, 'PRIMARY');
    END

    PRINT N'Filegroup użyty dla NEXT USED: ' + @FileGroupName;

    IF @WhatIf = 1
    BEGIN
        PRINT N'--WhatIf-- Wykonano by:';
        PRINT N'ALTER PARTITION SCHEME ' + QUOTENAME(@PartitionSchemeName) + N' NEXT USED ' + QUOTENAME(@FileGroupName) + N';';
        PRINT N'ALTER PARTITION FUNCTION ' + QUOTENAME(@PartitionFunctionName) + N'() SPLIT RANGE (' + CONVERT(VARCHAR(20), @BoundaryValue) + N');';
        RETURN;
    END

    ----------------------------------------------------------------------
    -- 7. NEXT USED + SPLIT RANGE
    ----------------------------------------------------------------------
    BEGIN TRY
        SET @SQL = N'ALTER PARTITION SCHEME ' + QUOTENAME(@PartitionSchemeName)
                 + N' NEXT USED ' + QUOTENAME(@FileGroupName) + N';';
        EXEC sp_executesql @SQL;

        SET @SQL = N'ALTER PARTITION FUNCTION ' + QUOTENAME(@PartitionFunctionName)
                 + N'() SPLIT RANGE (' + CONVERT(VARCHAR(20), @BoundaryValue) + N');';
        EXEC sp_executesql @SQL;

        PRINT N'OK: dodano nową granicę partycji: ' + CONVERT(VARCHAR(20), @BoundaryValue);
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(N'Błąd podczas dodawania granicy partycji: %s', 16, 1, @ErrMsg);
    END CATCH
END
GO