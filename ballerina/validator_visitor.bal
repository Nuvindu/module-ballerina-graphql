// Copyright (c) 2020, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import graphql.parser;

class ValidatorVisitor {
    *parser:Visitor;

    private final __Schema schema;
    private final parser:DocumentNode documentNode;
    private ErrorDetail[] errors;
    private map<string> usedFragments;

    isolated function init(__Schema schema, parser:DocumentNode documentNode) {
        self.schema = schema;
        self.documentNode = documentNode;
        self.errors = [];
        self.usedFragments = {};
    }

    public isolated function validate() returns ErrorDetail[]? {
        self.visitDocument(self.documentNode);
        if (self.errors.length() > 0) {
            return self.errors;
        }
    }

    public isolated function visitDocument(parser:DocumentNode documentNode, anydata data = ()) {
        parser:OperationNode[] operations = documentNode.getOperations();
        foreach parser:OperationNode operationNode in operations {
            self.visitOperation(operationNode);
        }
    }

    public isolated function visitOperation(parser:OperationNode operationNode, anydata data = ()) {
        __Field? schemaFieldForOperation = self.createSchemaFieldFromOperation(operationNode);
        if schemaFieldForOperation is __Field {
            foreach parser:Selection selection in operationNode.getSelections() {
                self.visitSelection(selection, schemaFieldForOperation);
            }
        }
    }

    public isolated function visitSelection(parser:Selection selection, anydata data = ()) {
        __Field parentField = <__Field>data;
        __Type parentType = <__Type>getOfType(parentField.'type);
        if parentType.kind == UNION {
            self.validateUnionTypeField(selection, parentType, parentField);
            return;
        }
        if selection.isFragment {
            // This will be nil if the fragment is not found. The error is recorded in the fragment visitor.
            // Therefore nil value is ignored.
            var node = selection?.node;
            if node is () {
                return;
            }
            __Type? fragmentOnType = self.validateFragment(selection, <string>parentType?.name);
            if fragmentOnType is __Type {
                parentField = createField(fragmentOnType?.name.toString(), fragmentOnType);
                parser:FragmentNode fragmentNode = <parser:FragmentNode>node;
                self.visitFragment(fragmentNode, parentField);
            }
        } else {
            parser:FieldNode fieldNode = <parser:FieldNode>selection?.node;
            self.visitField(fieldNode, parentField);
        }
    }

    public isolated function visitField(parser:FieldNode fieldNode, anydata data = ()) {
        __Field parentField = <__Field>data;
        __Type parentType = getOfType(parentField.'type);
        __Field? requiredFieldValue = self.getRequierdFieldFromType(parentType, fieldNode);
        if requiredFieldValue is () {
            string message = getFieldNotFoundErrorMessageFromType(fieldNode.getName(), parentType);
            self.errors.push(getErrorDetailRecord(message, fieldNode.getLocation()));
            return;
        }
        __Field requiredField = <__Field>requiredFieldValue;
        __Type fieldType = getOfType(requiredField.'type);
        __Field[] subFields = getFieldsArrayFromType(fieldType);
        self.checkArguments(parentType, fieldNode, requiredField);

        if !hasFields(fieldType) && fieldNode.getSelections().length() == 0 {
            return;
        } else if !hasFields(fieldType) && fieldNode.getSelections().length() > 0 {
            string message = getNoSubfieldsErrorMessage(requiredField);
            self.errors.push(getErrorDetailRecord(message, fieldNode.getLocation()));
            return;
        } else if hasFields(fieldType) && fieldNode.getSelections().length() == 0 {
            // TODO: The location of this error should be the location of open brace after the field node.
            // Currently, we use the field location for this.
            string message = getMissingSubfieldsErrorFromType(requiredField);
            self.errors.push(getErrorDetailRecord(message, fieldNode.getLocation()));
            return;
        } else {
            foreach parser:Selection selection in fieldNode.getSelections() {
                self.visitSelection(selection, requiredField);
            }
        }
    }

    public isolated function visitArgument(parser:ArgumentNode argumentNode, anydata data = ()) {
        __InputValue schemaArg = <__InputValue>data;
        __Type argType = getOfType(schemaArg.'type);
        string expectedTypeName = argType?.name.toString();
        parser:ArgumentValue value = argumentNode.getValue();
        if (argType.kind == ENUM) {
            self.validateEnumArgument(argType, argumentNode, schemaArg);
        } else {
            string actualTypeName = getTypeName(argumentNode);
            if (expectedTypeName == actualTypeName) {
                return;
            }
            if (expectedTypeName == FLOAT && actualTypeName == INT) {
                self.coerceInputIntToFloat(argumentNode);
                return;
            }
            string message =
                string`${expectedTypeName} cannot represent non ${expectedTypeName} value: ${value.value.toString()}`;
            ErrorDetail errorDetail = getErrorDetailRecord(message, value.location);
            self.errors.push(errorDetail);
        }
    }

    public isolated function visitFragment(parser:FragmentNode fragmentNode, anydata data = ()) {
        foreach parser:Selection selection in fragmentNode.getSelections() {
            self.visitSelection(selection, data);
        }
    }

    isolated function validateUnionTypeField(parser:Selection selection, __Type parentType, __Field parentField) {
        if !selection.isFragment {
            parser:FieldNode fieldNode = <parser:FieldNode>selection?.node;
            __Field? subField = self.getRequierdFieldFromType(parentType, fieldNode);
            if subField is __Field {
                self.visitField(fieldNode, subField);
            } else {
                string message = getInvalidFieldOnUnionTypeError(selection.name, parentType);
                self.errors.push(getErrorDetailRecord(message, selection.location));
            }
        } else {
            parser:FragmentNode fragmentNode = <parser:FragmentNode>selection?.node;
            __Type? requiredType = getTypeFromTypeArray(<__Type[]>parentType?.possibleTypes, fragmentNode.getOnType());
            if requiredType is __Type {
                __Field subField = createField(parentField.name, requiredType);
                self.visitFragment(fragmentNode, subField);
            } else {
                string message = getFragmetCannotSpreadError(fragmentNode, selection.name, parentType);
                self.errors.push(getErrorDetailRecord(message, <Location>selection?.spreadLocation));
            }
        }
    }

    isolated function coerceInputIntToFloat(parser:ArgumentNode argument) {
        parser:ArgumentValue argumentValue = argument.getValue();
        argumentValue.value = <float>argument.getValue().value;
    }

    isolated function getErrors() returns ErrorDetail[] {
        return self.errors;
    }

    isolated function checkArguments(__Type parentType, parser:FieldNode fieldNode, __Field schemaField) {
        __InputValue[] inputValues = schemaField.args;
        __InputValue[] notFoundInputValues = [];

        notFoundInputValues = copyInputValueArray(inputValues);
        foreach parser:ArgumentNode argumentNode in fieldNode.getArguments() {
            string argName = argumentNode.getName().value;
            __InputValue? inputValue = getInputValueFromArray(inputValues, argName);
            if inputValue is __InputValue {
                _ = notFoundInputValues.remove(<int>notFoundInputValues.indexOf(inputValue));
                self.visitArgument(argumentNode, inputValue);
            } else {
                string parentName = parentType?.name is string ? <string>parentType?.name : "";
                string message = getUnknownArgumentErrorMessage(argName, parentName, fieldNode.getName());
                self.errors.push(getErrorDetailRecord(message, argumentNode.getName().location));
            }
        }

        foreach __InputValue inputValue in notFoundInputValues {
            if (inputValue.'type.kind == NON_NULL && inputValue?.defaultValue is ()) {
                string message = getMissingRequiredArgError(fieldNode, inputValue);
                self.errors.push(getErrorDetailRecord(message, fieldNode.getLocation()));
            }
        }
    }

    isolated function validateFragment(parser:Selection fragment, string schemaTypeName) returns __Type? {
        parser:FragmentNode fragmentNode = <parser:FragmentNode>self.documentNode.getFragment(fragment.name);
        string fragmentOnTypeName = fragmentNode.getOnType();
        __Type? fragmentOnType = getTypeFromTypeArray(self.schema.types, fragmentOnTypeName);
        if (fragmentOnType is ()) {
            string message = string`Unknown type "${fragmentOnTypeName}".`;
            ErrorDetail errorDetail = getErrorDetailRecord(message, fragment.location);
            self.errors.push(errorDetail);
        } else {
            __Type schemaType = <__Type>getTypeFromTypeArray(self.schema.types, schemaTypeName);
            __Type ofType = getOfType(schemaType);
            if (fragmentOnType != ofType) {
                string message = getFragmetCannotSpreadError(fragmentNode, fragment.name, ofType);
                ErrorDetail errorDetail = getErrorDetailRecord(message, <Location>fragment?.spreadLocation);
                self.errors.push(errorDetail);
            }
            return fragmentOnType;
        }
    }

    isolated function validateEnumArgument(__Type argType, parser:ArgumentNode argNode, __InputValue inputValue) {
        parser:ArgumentValue value = argNode.getValue();
        if argNode.getKind() != parser:T_IDENTIFIER {
            string message =
                string`Enum "${getTypeNameFromType(argType)}" cannot represent non-enum value: "${value.value}"`;
            ErrorDetail errorDetail = getErrorDetailRecord(message, value.location);
            self.errors.push(errorDetail);
            return;
        }
       __EnumValue[] enumValues = <__EnumValue[]>argType?.enumValues;
        foreach __EnumValue enumValue in enumValues {
            if (enumValue.name == value.value) {
                return;
            }
        }
        string message = string`Value "${value.value}" does not exist in "${inputValue.name}" enum.`;
        ErrorDetail errorDetail = getErrorDetailRecord(message, value.location);
        self.errors.push(errorDetail);
    }

    isolated function createSchemaFieldFromOperation(parser:OperationNode operationNode) returns __Field? {
        parser:RootOperationType operationType = operationNode.getKind();
        string operationTypeName = getOperationTypeNameFromOperationType(operationType);
        __Type? 'type = getTypeFromTypeArray(self.schema.types, operationTypeName);
        if 'type == () {
            string message = string`Schema is not configured for ${operationType.toString()}s.`;
            self.errors.push(getErrorDetailRecord(message, operationNode.getLocation()));
        } else {
            return createField(operationTypeName, 'type);
        }
    }

    isolated function getFieldFromFieldArray(__Field[] fields, string fieldName) returns __Field? {
        foreach __Field schemaField in fields {
            if schemaField.name == fieldName {
                return schemaField;
            }
        }
    }

    isolated function getRequierdFieldFromType(__Type parentType, parser:FieldNode fieldNode) returns __Field? {
        __Field[] fields = getFieldsArrayFromType(parentType);
        __Field? requiredField = self.getFieldFromFieldArray(fields, fieldNode.getName());
        if requiredField is () {
            if fieldNode.getName() == SCHEMA_FIELD && parentType?.name == QUERY_TYPE_NAME {
                __Type fieldType = <__Type>getTypeFromTypeArray(self.schema.types, SCHEMA_TYPE_NAME);
                requiredField = createField(SCHEMA_FIELD, fieldType);
            } else if fieldNode.getName() == TYPE_FIELD && parentType?.name == QUERY_TYPE_NAME {
                __Type fieldType = <__Type>getTypeFromTypeArray(self.schema.types, TYPE_TYPE_NAME);
                __Type argumentType = <__Type>getTypeFromTypeArray(self.schema.types, STRING);
                __Type wrapperType = { kind: NON_NULL, ofType: argumentType };
                __InputValue[] args = [{ name: NAME_ARGUMENT, 'type: wrapperType }];
                requiredField = createField(TYPE_FIELD, fieldType, args);
            } else if fieldNode.getName() == TYPE_NAME_FIELD {
                __Type ofType = <__Type>getTypeFromTypeArray(self.schema.types, STRING);
                __Type wrappingType = { kind: NON_NULL, ofType: ofType };
                requiredField = createField(TYPE_NAME_FIELD, wrappingType);
            }
        }
        return requiredField;
    }
}

isolated function copyInputValueArray(__InputValue[] original) returns __InputValue[] {
    __InputValue[] result = [];
    foreach __InputValue inputValue in original {
        result.push(inputValue);
    }
    return result;
}

isolated function getInputValueFromArray(__InputValue[] inputValues, string name) returns __InputValue? {
    foreach __InputValue inputValue in inputValues {
        if (inputValue.name == name) {
            return inputValue;
        }
    }
}

isolated function getTypeFromTypeArray(__Type[] types, string typeName) returns __Type? {
    foreach __Type schemaType in types {
        __Type ofType = getOfType(schemaType);
        if (ofType?.name.toString() == typeName) {
            return ofType;
        }
    }
}

isolated function hasFields(__Type fieldType) returns boolean {
    if (fieldType.kind == OBJECT || fieldType.kind == UNION) {
        return true;
    }
    return false;
}

isolated function getOperationTypeNameFromOperationType(parser:RootOperationType rootOperationType) returns string {
    match rootOperationType {
        parser:MUTATION => {
            return MUTATION_TYPE_NAME;
        }
        parser:SUBSCRIPTION => {
            return SUBSCRIPTION_TYPE_NAME;
        }
        _ => {
            return QUERY_TYPE_NAME;
        }
    }
}

isolated function createField(string fieldName, __Type fieldType, __InputValue[] args = []) returns __Field {
    return {
        name: fieldName,
        'type: fieldType,
        args: args
    };
}

isolated function getFieldsArrayFromType(__Type 'type) returns __Field[] {
    __Field[]? fields = 'type?.fields;
    return fields == () ? [] : fields;
}