module Step.Decode exposing
    ( File, Header, Entity, Attribute, Error
    , Decoder, FileDecoder, EntityDecoder, AttributeListDecoder, AttributeDecoder
    , file
    , header, single, all
    , entity
    , attribute
    , bool, int, float, string, referenceTo, null, optional, list, tuple2, tuple3, derived
    , succeed, fail, map, map2, map3, map4, map5, map6, map7, map8, andThen, oneOf, lazy
    )

{-|

@docs File, Header, Entity, SimpleEntity, ComplexEntity, Attribute, Error

@docs Decoder, FileDecoder, EntityDecoder, AttributeListDecoder, AttributeDecoder

@docs file

@docs header, single, all

@docs entity

@docs attribute

@docs bool, int, float, string, referenceTo, null, optional, list, tuple2, tuple3, derived

@docs succeed, fail, map, map2, map3, map4, map5, map6, map7, map8, andThen, oneOf, lazy

-}

import Bitwise
import Dict
import List
import List.Extra as List
import Parser exposing ((|.), (|=), Parser)
import Step.EntityResolution as EntityResolution
import Step.FastParse as FastParse
import Step.Header as Header
import Step.TypeName as TypeName
import Step.Types as Types exposing (Attribute, Entity, EntityRecord, File)


type alias File =
    Types.File


type alias Header =
    Header.Header


type alias Entity =
    Types.Entity


type alias Attribute =
    Types.Attribute


type alias Error =
    Types.Error


{-| A `Decoder` describes how to attempt to decode a given `File`, `Entity` or
`Attribute` to produce a value of another type. See the `Decode` module for
details on how to use and construct decoders.
-}
type Decoder i x a
    = Decoder (i -> DecodeResult x a)


type DecodeResult x a
    = Succeeded a
    | Failed String
    | NotMatched x


type alias FileDecoder a =
    Decoder File Never a


type alias EntityDecoder a =
    Decoder Entity String a


type alias AttributeListDecoder a =
    Decoder (List Attribute) Never a


type alias AttributeDecoder a =
    Decoder Attribute Never a


run : Decoder i x a -> i -> DecodeResult x a
run (Decoder function) input =
    function input


succeed : a -> Decoder i x a
succeed value =
    Decoder (always (Succeeded value))


fail : String -> Decoder i x a
fail description =
    Decoder (always (Failed description))


{-| Decode a STEP file given as a `String` using the given decoder.
-}
file : FileDecoder a -> String -> Result Error a
file decoder contents =
    FastParse.parse contents
        |> Result.andThen
            (\parsedFile ->
                case run decoder parsedFile of
                    Succeeded value ->
                        Ok value

                    Failed message ->
                        Err (Types.DecodeError message)

                    NotMatched notMatched ->
                        never notMatched
            )


{-| Extract the header of a STEP file.
-}
header : FileDecoder Header
header =
    Decoder (\(Types.File properties) -> Succeeded properties.header)


single : EntityDecoder a -> FileDecoder a
single entityDecoder =
    Decoder
        (\(Types.File { entities }) ->
            singleEntity entityDecoder (Dict.values entities) Nothing
        )


singleEntity : EntityDecoder a -> List Entity -> Maybe a -> DecodeResult Never a
singleEntity decoder entities currentValue =
    case entities of
        [] ->
            case currentValue of
                Just value ->
                    Succeeded value

                Nothing ->
                    Failed "No matching entities found"

        first :: rest ->
            case run decoder first of
                Succeeded value ->
                    case currentValue of
                        Nothing ->
                            singleEntity decoder rest (Just value)

                        Just _ ->
                            Failed "More than one matching entity found"

                Failed message ->
                    Failed message

                NotMatched _ ->
                    singleEntity decoder rest currentValue


all : EntityDecoder a -> FileDecoder (List a)
all entityDecoder =
    Decoder
        (\(Types.File { entities }) ->
            allEntities entityDecoder (Dict.values entities) []
        )


allEntities : EntityDecoder a -> List Entity -> List a -> DecodeResult Never (List a)
allEntities decoder entities accumulated =
    case entities of
        [] ->
            Succeeded (List.reverse accumulated)

        first :: rest ->
            case run decoder first of
                Succeeded value ->
                    allEntities decoder rest (value :: accumulated)

                Failed message ->
                    Failed message

                NotMatched _ ->
                    allEntities decoder rest accumulated


entity : String -> AttributeListDecoder a -> EntityDecoder a
entity givenTypeName decoder =
    let
        searchTypeName =
            TypeName.fromString givenTypeName
    in
    Decoder
        (\currentEntity ->
            case currentEntity of
                Types.SimpleEntity entityRecord ->
                    if entityRecord.typeName == searchTypeName then
                        case run decoder entityRecord.attributes of
                            Succeeded a ->
                                Succeeded a

                            Failed message ->
                                Failed message

                            NotMatched notMatched ->
                                never notMatched

                    else
                        NotMatched
                            ("Expected entity of type '"
                                ++ TypeName.toString searchTypeName
                                ++ "', got '"
                                ++ TypeName.toString entityRecord.typeName
                                ++ "'"
                            )

                Types.ComplexEntity entityRecords ->
                    partialEntity searchTypeName decoder entityRecords
        )


partialEntity : Types.TypeName -> AttributeListDecoder a -> List EntityRecord -> DecodeResult String a
partialEntity searchTypeName decoder entityRecords =
    case entityRecords of
        [] ->
            NotMatched
                ("Complex entity has no sub-entity of type '"
                    ++ TypeName.toString searchTypeName
                    ++ "'"
                )

        first :: rest ->
            if first.typeName == searchTypeName then
                case run decoder first.attributes of
                    Succeeded value ->
                        Succeeded value

                    Failed message ->
                        Failed message

                    NotMatched notMatched ->
                        never notMatched

            else
                partialEntity searchTypeName decoder rest


attribute : Int -> AttributeDecoder a -> AttributeListDecoder a
attribute index attributeDecoder =
    Decoder
        (\attributeList ->
            case List.getAt index attributeList of
                Just entityAttribute ->
                    run attributeDecoder entityAttribute

                Nothing ->
                    Failed ("No attribute at index " ++ String.fromInt index)
        )


mapHelp : (a -> b) -> DecodeResult x a -> DecodeResult x b
mapHelp function result =
    case result of
        Succeeded value ->
            Succeeded (function value)

        Failed message ->
            Failed message

        NotMatched message ->
            NotMatched message


map : (a -> b) -> Decoder i x a -> Decoder i x b
map mapFunction decoder =
    Decoder (\input -> mapHelp mapFunction (run decoder input))


map2Help : (a -> b -> c) -> DecodeResult x a -> DecodeResult x b -> DecodeResult x c
map2Help function resultA resultB =
    case resultA of
        Succeeded value ->
            mapHelp (function value) resultB

        NotMatched message ->
            NotMatched message

        Failed message ->
            Failed message


map2 :
    (a -> b -> c)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
map2 function (Decoder functionA) (Decoder functionB) =
    Decoder (\input -> map2Help function (functionA input) (functionB input))


map3 :
    (a -> b -> c -> d)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
map3 function decoderA decoderB decoderC =
    map2 (<|) (map2 function decoderA decoderB) decoderC


map4 :
    (a -> b -> c -> d -> e)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
    -> Decoder i x e
map4 function decoderA decoderB decoderC decoderD =
    map2 (<|) (map3 function decoderA decoderB decoderC) decoderD


map5 :
    (a -> b -> c -> d -> e -> f)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
    -> Decoder i x e
    -> Decoder i x f
map5 function decoderA decoderB decoderC decoderD decoderE =
    map2 (<|) (map4 function decoderA decoderB decoderC decoderD) decoderE


map6 :
    (a -> b -> c -> d -> e -> f -> g)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
    -> Decoder i x e
    -> Decoder i x f
    -> Decoder i x g
map6 function decoderA decoderB decoderC decoderD decoderE decoderF =
    map2 (<|) (map5 function decoderA decoderB decoderC decoderD decoderE) decoderF


map7 :
    (a -> b -> c -> d -> e -> f -> g -> h)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
    -> Decoder i x e
    -> Decoder i x f
    -> Decoder i x g
    -> Decoder i x h
map7 function decoderA decoderB decoderC decoderD decoderE decoderF decoderG =
    map2 (<|) (map6 function decoderA decoderB decoderC decoderD decoderE decoderF) decoderG


map8 :
    (a -> b -> c -> d -> e -> f -> g -> h -> j)
    -> Decoder i x a
    -> Decoder i x b
    -> Decoder i x c
    -> Decoder i x d
    -> Decoder i x e
    -> Decoder i x f
    -> Decoder i x g
    -> Decoder i x h
    -> Decoder i x j
map8 function decoderA decoderB decoderC decoderD decoderE decoderF decoderG decoderH =
    map2 (<|) (map7 function decoderA decoderB decoderC decoderD decoderE decoderF decoderG) decoderH


bool : AttributeDecoder Bool
bool =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.BoolAttribute value ->
                    Succeeded value

                _ ->
                    Failed "Expected a bool"
        )


int : AttributeDecoder Int
int =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.IntAttribute value ->
                    Succeeded value

                _ ->
                    Failed "Expected an int"
        )


float : AttributeDecoder Float
float =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.FloatAttribute value ->
                    Succeeded value

                _ ->
                    Failed "Expected a float"
        )


isBasic : Char -> Bool
isBasic character =
    character /= '\'' && character /= '\\'


hexDigit : Parser Int
hexDigit =
    Parser.oneOf
        [ Parser.succeed 0 |. Parser.token "0"
        , Parser.succeed 1 |. Parser.token "1"
        , Parser.succeed 2 |. Parser.token "2"
        , Parser.succeed 3 |. Parser.token "3"
        , Parser.succeed 4 |. Parser.token "4"
        , Parser.succeed 5 |. Parser.token "5"
        , Parser.succeed 6 |. Parser.token "6"
        , Parser.succeed 7 |. Parser.token "7"
        , Parser.succeed 8 |. Parser.token "8"
        , Parser.succeed 9 |. Parser.token "9"
        , Parser.succeed 10 |. Parser.token "A"
        , Parser.succeed 11 |. Parser.token "B"
        , Parser.succeed 12 |. Parser.token "C"
        , Parser.succeed 13 |. Parser.token "D"
        , Parser.succeed 14 |. Parser.token "E"
        , Parser.succeed 15 |. Parser.token "F"
        ]


x0 : Int -> Int -> Char
x0 high low =
    Char.fromCode (low + Bitwise.shiftLeftBy 4 high)


x2 : Int -> Int -> Int -> Int -> Char
x2 a b c d =
    Char.fromCode <|
        d
            + Bitwise.shiftLeftBy 4 c
            + Bitwise.shiftLeftBy 8 b
            + Bitwise.shiftLeftBy 12 a


x4 : Int -> Int -> Int -> Int -> Int -> Int -> Char
x4 a b c d e f =
    Char.fromCode <|
        f
            + Bitwise.shiftLeftBy 4 e
            + Bitwise.shiftLeftBy 8 d
            + Bitwise.shiftLeftBy 12 c
            + Bitwise.shiftLeftBy 16 b
            + Bitwise.shiftLeftBy 20 a


parseX0 : Parser String
parseX0 =
    Parser.succeed (\a b -> String.fromChar (x0 a b))
        |. Parser.token "\\X\\"
        |= hexDigit
        |= hexDigit


parseX2 : Parser String
parseX2 =
    Parser.succeed String.fromList
        |. Parser.token "\\X2\\"
        |= Parser.loop []
            (\accumulated ->
                Parser.oneOf
                    [ Parser.succeed
                        (\a b c d ->
                            Parser.Loop (x2 a b c d :: accumulated)
                        )
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                    , Parser.succeed
                        (\() -> Parser.Done (List.reverse accumulated))
                        |= Parser.token "\\X0\\"
                    ]
            )


parseX4 : Parser String
parseX4 =
    Parser.succeed String.fromList
        |. Parser.token "\\X4\\"
        |= Parser.loop []
            (\accumulated ->
                Parser.oneOf
                    [ Parser.succeed
                        (\a b c d e f ->
                            Parser.Loop (x4 a b c d e f :: accumulated)
                        )
                        |. Parser.token "00"
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                        |= hexDigit
                    , Parser.succeed
                        (\() -> Parser.Done (List.reverse accumulated))
                        |= Parser.token "\\X0\\"
                    ]
            )


parseStringChunk : Parser String
parseStringChunk =
    Parser.oneOf
        [ Parser.getChompedString
            (Parser.chompIf isBasic |. Parser.chompWhile isBasic)
        , Parser.succeed "'" |. Parser.token "''"
        , Parser.succeed "\\" |. Parser.token "\\\\"
        , parseX0
        , parseX2
        , parseX4
        ]


parseString : Parser String
parseString =
    Parser.succeed String.concat
        |= Parser.loop []
            (\accumulated ->
                Parser.oneOf
                    [ Parser.succeed
                        (\chunk -> Parser.Loop (chunk :: accumulated))
                        |= parseStringChunk
                    , Parser.lazy
                        (\() ->
                            Parser.succeed <|
                                Parser.Done (List.reverse accumulated)
                        )
                    ]
            )


string : AttributeDecoder String
string =
    Decoder
        (\attribute_ ->
            case attribute_ of
                Types.StringAttribute encodedString ->
                    case Parser.run parseString encodedString of
                        Ok decodedString ->
                            Succeeded decodedString

                        Err err ->
                            Failed
                                ("Could not parse encoded string '"
                                    ++ encodedString
                                )

                _ ->
                    Failed "Expected a string"
        )


collectDecodedAttributes : AttributeDecoder a -> List a -> List Attribute -> DecodeResult Never (List a)
collectDecodedAttributes decoder accumulated remainingAttributes =
    case remainingAttributes of
        [] ->
            -- No more attributes to decode, so succeed with all the results we
            -- have collected so far
            Succeeded (List.reverse accumulated)

        first :: rest ->
            case run decoder first of
                -- Decoding succeeded on this attribute: continue with the
                -- rest
                Succeeded result ->
                    collectDecodedAttributes decoder (result :: accumulated) rest

                -- Decoding failed on this attribute: immediately abort
                -- with the returned error message
                Failed message ->
                    Failed message

                NotMatched notMatched ->
                    never notMatched


list : AttributeDecoder a -> AttributeDecoder (List a)
list itemDecoder =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.AttributeList attributes_ ->
                    collectDecodedAttributes itemDecoder [] attributes_

                _ ->
                    Failed "Expected a list"
        )


tuple2 : ( AttributeDecoder a, AttributeDecoder b ) -> AttributeDecoder ( a, b )
tuple2 ( firstDecoder, secondDecoder ) =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.AttributeList [ firstAttribute, secondAttribute ] ->
                    map2Help Tuple.pair
                        (run firstDecoder firstAttribute)
                        (run secondDecoder secondAttribute)

                _ ->
                    Failed "Expected a list of two items"
        )


tuple3 : ( AttributeDecoder a, AttributeDecoder b, AttributeDecoder c ) -> AttributeDecoder ( a, b, c )
tuple3 ( firstDecoder, secondDecoder, thirdDecoder ) =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.AttributeList [ firstAttribute, secondAttribute, thirdAttribute ] ->
                    map2Help (<|)
                        (map2Help (\first second third -> ( first, second, third ))
                            (run firstDecoder firstAttribute)
                            (run secondDecoder secondAttribute)
                        )
                        (run thirdDecoder thirdAttribute)

                _ ->
                    Failed "Expected a list of three items"
        )


referenceTo : EntityDecoder a -> AttributeDecoder a
referenceTo entityDecoder =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.ReferenceTo referencedEntity ->
                    case run entityDecoder referencedEntity of
                        Succeeded value ->
                            Succeeded value

                        Failed message ->
                            Failed message

                        NotMatched message ->
                            Failed message

                _ ->
                    Failed "Expected a referenced entity"
        )


oneOf : List (EntityDecoder a) -> EntityDecoder a
oneOf decoders =
    Decoder (oneOfHelp decoders [])


oneOfHelp : List (EntityDecoder a) -> List String -> Entity -> DecodeResult String a
oneOfHelp decoders matchErrors input =
    case decoders of
        [] ->
            -- No more decoders to try: fail with an error message that
            -- aggregates all the individual error messages
            Failed
                ("No decoders matched (error messages: \""
                    ++ String.join "\", \"" (List.reverse matchErrors)
                    ++ "\")"
                )

        first :: rest ->
            -- At least one decoder left to try, so try it
            case run first input of
                -- Decoding succeeded: return the result
                Succeeded result ->
                    Succeeded result

                -- Decoder matched the entity (based on type name) but then
                -- failed decoding; in this case consider that the decoder has
                -- 'committed' to decoding and so report the error instead of
                -- ignoring it and moving to the next decoder
                Failed message ->
                    Failed message

                -- Decoder did not match the entity: move on to the next one,
                -- but save the error message in case *all* decoders do not
                -- match (see above)
                NotMatched matchError ->
                    oneOfHelp rest (matchError :: matchErrors) input


null : a -> AttributeDecoder a
null value =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.NullAttribute ->
                    Succeeded value

                _ ->
                    Failed "Expecting null attribute ($)"
        )


derived : a -> AttributeDecoder a
derived value =
    Decoder
        (\inputAttribute ->
            case inputAttribute of
                Types.DerivedAttribute ->
                    Succeeded value

                _ ->
                    Failed "Expecting 'derived value' attribute (*)"
        )


optional : AttributeDecoder a -> AttributeDecoder (Maybe a)
optional decoder =
    Decoder
        (\inputAttribute ->
            case run decoder inputAttribute of
                Succeeded value ->
                    Succeeded (Just value)

                Failed message ->
                    case inputAttribute of
                        Types.NullAttribute ->
                            Succeeded Nothing

                        _ ->
                            Failed message

                NotMatched notMatched ->
                    never notMatched
        )


andThen : (a -> Decoder i Never b) -> Decoder i x a -> Decoder i x b
andThen function decoder =
    Decoder
        (\input ->
            case run decoder input of
                Succeeded intermediateValue ->
                    case run (function intermediateValue) input of
                        Succeeded value ->
                            Succeeded value

                        Failed message ->
                            Failed message

                        NotMatched notMatched ->
                            never notMatched

                Failed message ->
                    Failed message

                NotMatched notMatched ->
                    NotMatched notMatched
        )


lazy : (() -> Decoder i x a) -> Decoder i x a
lazy constructor =
    Decoder (\input -> run (constructor ()) input)
