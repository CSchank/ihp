module IHP.IDE.SchemaDesigner.Controller.Columns where

import IHP.ControllerPrelude
import IHP.IDE.ToolServer.Types

import IHP.IDE.SchemaDesigner.View.Columns.New
import IHP.IDE.SchemaDesigner.View.Columns.Edit
import IHP.IDE.SchemaDesigner.View.Columns.NewForeignKey
import IHP.IDE.SchemaDesigner.View.Columns.EditForeignKey

import IHP.IDE.SchemaDesigner.Types
import IHP.IDE.SchemaDesigner.View.Layout (schemaDesignerLayout, findStatementByName, replace, getDefaultValue, findForeignKey, findTableIndex)
import IHP.IDE.SchemaDesigner.Controller.Helper
import IHP.IDE.SchemaDesigner.Controller.Validation

import qualified Data.Text as Text
import qualified Data.Maybe as Maybe
import qualified Data.List as List

instance Controller ColumnsController where
    beforeAction = setLayout schemaDesignerLayout

    action NewColumnAction { tableName } = do
        statements <- readSchema
        let (Just table) = findStatementByName tableName statements
        let tableNames = nameList (getCreateTable statements)
        let enumNames = nameList (getCreateEnum statements)
        render NewColumnView { .. }

    action CreateColumnAction = do
        let tableName = param "tableName"
        let defaultValue = getDefaultValue (param "columnType") (param "defaultValue")
        let columnName = param "name"
        let validationResult = columnName |> validateColumn
        case validationResult of
            Failure message ->
                setErrorMessage message
            Success -> do
                let column = Column
                        { name = columnName
                        , columnType = arrayifytype (param "isArray") (param "columnType")
                        , defaultValue = defaultValue
                        , notNull = (not (param "allowNull"))
                        , isUnique = param "isUnique"
                        }
                updateSchema (map (addColumnToTable tableName column (param "primaryKey")))
                when (param "isReference") do
                    let columnName = param "name"
                    let constraintName = tableName <> "_ref_" <> columnName
                    let referenceTable = param "referenceTable"
                    let onDelete = NoAction
                    let addForeignKeyConstraintToSchema = addForeignKeyConstraint tableName columnName constraintName referenceTable onDelete

                    let indexName = tableName <> "_" <> columnName <> "_index"
                    let columnNames = [columnName]
                    let addTableIndexToSchema = addTableIndex indexName False tableName columnNames

                    updateSchema (addForeignKeyConstraintToSchema . addTableIndexToSchema)

        redirectTo ShowTableAction { .. }

    action EditColumnAction { .. } = do
        let columnId = param "columnId"
        let name = tableName
        statements <- readSchema
        let (Just table) = findStatementByName name statements
        let table = findStatementByName tableName statements
        let columns = maybe [] (get #columns . unsafeGetCreateTable) table
        let column = columns !! columnId
        let enumNames = nameList (getCreateEnum statements)
        render EditColumnView { .. }

    action UpdateColumnAction = do
        statements <- readSchema
        let tableName = param "tableName"
        let columnName = param "name"
        let validationResult = columnName |> validateColumn
        case validationResult of
            Failure message ->
                setErrorMessage message
            Success -> do
                let defaultValue = getDefaultValue (param "columnType") (param "defaultValue")
                let table = findStatementByName tableName statements
                let columns = maybe [] (get #columns . unsafeGetCreateTable) table
                let columnId = param "columnId"
                let column = Column
                        { name = columnName
                        , columnType = arrayifytype (param "isArray") (param "columnType")
                        , defaultValue = defaultValue
                        , notNull = (not (param "allowNull"))
                        , isUnique = param "isUnique"
                        }
                when ((get #name column) == "") do
                    setErrorMessage ("Column Name can not be empty")
                    redirectTo ShowTableAction { tableName }
                updateSchema (map (updateColumnInTable tableName column (param "primaryKey") columnId))

                -- Update Foreign Key Reference
                let oldColumn = columns !! columnId
                let oldColumnName = get #name oldColumn
                let maybeConstraint = referencingColumnForeignKeyConstraints tableName oldColumnName statements
                case maybeConstraint of
                    Just constraint -> do
                        let Just constraintId = elemIndex constraint statements
                        let constraintName = tableName <> "_ref_" <> columnName
                        let referenceTable = Text.splitOn "_id" columnName |> head |> Maybe.fromJust |> pluralize
                        let Just onDelete = get #onDelete (get #constraint constraint)
                        updateSchema (updateForeignKeyConstraint tableName columnName constraintName referenceTable onDelete constraintId)
                    Nothing -> pure ()
        redirectTo ShowTableAction { .. }

    action DeleteColumnAction { .. } = do
        statements <- readSchema
        let tableName = param "tableName"
        let columnId = param "columnId"
        let columnName = param "columnName"
        case findForeignKey statements tableName columnName of
            Just AddConstraint { constraintName, .. } -> updateSchema (deleteForeignKeyConstraint constraintName)
            otherwise -> pure ()

        let indicesToDelete = findIndicesReferencingColumn statements (tableName, columnName)
        forEach indicesToDelete \CreateIndex { indexName } -> updateSchema (deleteTableIndex indexName)
        updateSchema (map (deleteColumnInTable tableName columnId))
        redirectTo ShowTableAction { .. }

    action ToggleColumnUniqueAction { .. } = do
        let tableName = param "tableName"
        let columnId = param "columnId"
        updateSchema (map (toggleUniqueInColumn tableName columnId))
        redirectTo ShowTableAction { .. }

    -- FOREIGN KEYS
    action NewForeignKeyAction { tableName, columnName } = do
        let name = tableName
        statements <- readSchema
        let tableNames = nameList (getCreateTable statements)
        render NewForeignKeyView { .. }

    action CreateForeignKeyAction = do
        let tableName = param "tableName"
        let columnName = param "columnName"
        let constraintName = param "constraintName"
        let referenceTable = param "referenceTable"
        let onDelete = NoAction
        updateSchema (addForeignKeyConstraint tableName columnName constraintName referenceTable onDelete)
        redirectTo ShowTableAction { .. }

    action EditForeignKeyAction { tableName, columnName, constraintName, referenceTable } = do
        let name = tableName
        statements <- readSchema
        let tableNames = nameList (getCreateTable statements)
        let (Just statement) = find (\statement -> statement == AddConstraint { tableName = tableName, constraintName = constraintName, constraint = ForeignKeyConstraint { columnName = columnName, referenceTable = referenceTable, referenceColumn = "id", onDelete = (get #onDelete (get #constraint statement)) }}) statements
        onDelete <- case (get #onDelete (get #constraint statement)) of
            Just NoAction -> do pure "NoAction"
            Just Restrict -> do pure "Restrict"
            Just SetNull -> do pure "SetNull"
            Just SetDefault -> do pure "SetDefault"
            Just Cascade -> do pure "Cascade"
            Nothing -> do pure "NoAction"
        render EditForeignKeyView { .. }

    action UpdateForeignKeyAction = do
        statements <- readSchema
        let tableName = param "tableName"
        let columnName = param "columnName"
        let constraintName = param "constraintName"
        let referenceTable = param "referenceTable"
        let constraintId = findIndex (\statement -> statement == AddConstraint { tableName = tableName
            , constraintName = (get #constraintName statement)
            , constraint = ForeignKeyConstraint
                { columnName = columnName
                , referenceTable = (get #referenceTable (get #constraint statement))
                , referenceColumn = (get #referenceColumn (get #constraint statement))
                , onDelete=(get #onDelete (get #constraint statement)) } }) statements
        let onDeleteParam = param @Text "onDelete"
        let onDelete = case onDeleteParam of
                "Restrict" -> Restrict
                "SetNull" -> SetNull
                "SetDefault" -> SetDefault
                "Cascade" -> Cascade
                _ -> NoAction
        case constraintId of
            Just constraintId -> updateSchema (updateForeignKeyConstraint tableName columnName constraintName referenceTable onDelete constraintId)
            Nothing -> putStrLn ("Error")
        redirectTo ShowTableAction { .. }

    action DeleteForeignKeyAction { constraintName, tableName } = do
        statements <- readSchema
        updateSchema (deleteForeignKeyConstraint constraintName)
        redirectTo ShowTableAction { .. }

addColumnToTable :: Text -> Column -> Bool -> Statement -> Statement
addColumnToTable tableName (column@Column { name = columnName }) isPrimaryKey (StatementCreateTable table@CreateTable { name, columns, primaryKeyConstraint = PrimaryKeyConstraint pks})
    | name == tableName =
        let primaryKeyConstraint =
              if isPrimaryKey
              then PrimaryKeyConstraint (pks <> [columnName])
              else PrimaryKeyConstraint pks
        in StatementCreateTable (table { columns = columns <> [column] , primaryKeyConstraint })
addColumnToTable tableName column isPrimaryKey statement = statement

updateColumnInTable :: Text -> Column -> Bool -> Int -> Statement -> Statement
updateColumnInTable tableName column isPrimaryKey columnId (StatementCreateTable table@CreateTable { name, columns, primaryKeyConstraint })
    | name == tableName = StatementCreateTable $
        table
            { columns = (replace columnId column columns)
            , primaryKeyConstraint = updatePrimaryKeyConstraint column isPrimaryKey primaryKeyConstraint
            }
updateColumnInTable tableName column isPrimaryKey columnId statement = statement

-- | Add or remove a column from the primary key constraint
updatePrimaryKeyConstraint :: Column -> Bool -> PrimaryKeyConstraint -> PrimaryKeyConstraint
updatePrimaryKeyConstraint Column { name } isPrimaryKey primaryKeyConstraint@PrimaryKeyConstraint { primaryKeyColumnNames } =
  case (isPrimaryKey, name `elem` primaryKeyColumnNames) of
      (False, False) -> primaryKeyConstraint
      (False, True) -> PrimaryKeyConstraint (filter (/= name) primaryKeyColumnNames)
      (True, False) -> PrimaryKeyConstraint (primaryKeyColumnNames <> [name])
      (True, True) -> primaryKeyConstraint

toggleUniqueInColumn :: Text -> Int -> Statement -> Statement
toggleUniqueInColumn tableName columnId (StatementCreateTable table@CreateTable { name, columns })
    | name == tableName = StatementCreateTable $
        table { columns = (replace columnId ((columns !! columnId) { isUnique = (not (get #isUnique (columns !! columnId))) }) columns) }
toggleUniqueInColumn tableName columnId statement = statement

deleteColumnInTable :: Text -> Int -> Statement -> Statement
deleteColumnInTable tableName columnId (StatementCreateTable table@CreateTable { name, columns })
    | name == tableName = StatementCreateTable $
        table { columns = delete (columns !! columnId) columns}
deleteColumnInTable tableName columnId statement = statement

addForeignKeyConstraint :: Text -> Text -> Text -> Text -> OnDelete -> [Statement] -> [Statement]
addForeignKeyConstraint tableName columnName constraintName referenceTable onDelete list = list <> [AddConstraint { tableName = tableName, constraintName = constraintName, constraint = ForeignKeyConstraint { columnName = columnName, referenceTable = referenceTable, referenceColumn = "id", onDelete = (Just onDelete) } }]

updateForeignKeyConstraint :: Text -> Text -> Text -> Text -> OnDelete -> Int -> [Statement] -> [Statement]
updateForeignKeyConstraint tableName columnName constraintName referenceTable onDelete constraintId list = replace constraintId AddConstraint { tableName = tableName, constraintName = constraintName, constraint = ForeignKeyConstraint { columnName = columnName, referenceTable = referenceTable, referenceColumn = "id", onDelete = (Just onDelete) } } list

deleteForeignKeyConstraint :: Text -> [Statement] -> [Statement]
deleteForeignKeyConstraint constraintName list = filter (\con -> not (con == AddConstraint { tableName = get #tableName con, constraintName = constraintName, constraint = get #constraint con })) list

addTableIndex :: Text -> Bool -> Text -> [Text] -> [Statement] -> [Statement]
addTableIndex indexName unique tableName columnNames list = list <> [CreateIndex { indexName, unique, tableName, expressions = map VarExpression columnNames, whereClause = Nothing }]

deleteTableIndex :: Text -> [Statement] -> [Statement]
deleteTableIndex indexName list =
    list
    |> filter \case
        CreateIndex { indexName = indexName' } -> indexName' /= indexName
        otherwise -> True

getCreateTable :: [Statement] -> [CreateTable]
getCreateTable statements = foldr step [] statements
  where
    step (StatementCreateTable createTable) createTables = createTable : createTables
    step _ createTables = createTables

getCreateEnum statements = filter isCreateEnumType statements
isCreateEnumType CreateEnumType {} = True
isCreateEnumType _ = False

nameList statements = map (get #name) statements

arrayifytype :: Bool -> PostgresType -> PostgresType
arrayifytype False   (PArray coltype) = coltype
arrayifytype True  a@(PArray coltype) = a
arrayifytype False coltype = coltype
arrayifytype True  coltype = PArray coltype

validateColumn :: Validator Text
validateColumn = validateNameInSchema "column name" [] Nothing

referencingColumnForeignKeyConstraints tableName columnName statements =
    find (\statement ->
        statement ==
            AddConstraint
                { tableName = tableName
                , constraintName = (get #constraintName statement)
                , constraint =
                    ForeignKeyConstraint
                        { columnName = columnName
                        , referenceTable = (get #referenceTable (get #constraint statement))
                        , referenceColumn = (get #referenceColumn (get #constraint statement))
                        , onDelete = (get #onDelete (get #constraint statement))
                        }
                }
    ) statements


-- | Returns the list of CreateIndex statements that reference a specific column
--
-- E.g. given a schema like this:
-- > CREATE TABLE users (
-- >     email TEXT NOT NULL
-- > );
-- >
-- > CREATE UNIQUE INDEX users_email_index ON users (LOWER(email));
-- >
--
-- You can find all indices to the email column of the users table like this:
--
-- >>> findIndicesReferencingColumn database ("users", "email")
-- [CreateIndex { indexName = "users_email", unique = True, tableName = "users", expressions = [CallExpression "LOWER" [VarEpression "email"]] }]
--
findIndicesReferencingColumn :: [Statement] -> (Text, Text) -> [Statement]
findIndicesReferencingColumn database (tableName, columnName) = database |> filter isReferenced
    where
        -- | Returns True if a statement is an CreateIndex statement that references our specific column
        --
        -- An index references a table if it references the target table and one of the index expressions contains a reference to our column
        isReferenced :: Statement -> Bool
        isReferenced CreateIndex { tableName = indexTableName, expressions } = indexTableName == tableName && expressionsReferencesColumn expressions
        isReferenced otherwise = False

        -- | Returns True if a list of expressions references the columnName
        expressionsReferencesColumn :: [Expression] -> Bool
        expressionsReferencesColumn expressions = expressions
                |> map expressionReferencesColumn
                |> List.or

        -- | Walks the expression tree and returns True if there's a VarExpression with the column name
        expressionReferencesColumn :: Expression -> Bool
        expressionReferencesColumn = \case
            TextExpression _ -> False
            VarExpression varName -> varName == columnName
            CallExpression _ expressions -> expressions
                    |> map expressionReferencesColumn
                    |> List.or
            NotEqExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            EqExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            AndExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            IsExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            NotExpression a -> expressionReferencesColumn a
            OrExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            LessThanExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            LessThanOrEqualToExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            GreaterThanExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b
            GreaterThanOrEqualToExpression a b -> expressionReferencesColumn a || expressionReferencesColumn b