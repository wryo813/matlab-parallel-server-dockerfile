%   Copyright 2023-2025 The MathWorks, Inc.

classdef productsTest < matlab.unittest.TestCase
    % このフォークの Dockerfile は ADDITIONAL_PRODUCTS で 100 以上の製品を入れるため、
    % 完全一致ではなく、MJS クラスタに必要な製品を含む一部の製品が入っていることを確認する。

    methods(Test)
        function testInstalledToolboxesIncludeExpected( testCase )
            import matlab.unittest.constraints.IsSupersetOf

            % names of toolboxes that must be installed
            expectedTbxNames = [...
                "Parallel Computing Toolbox",...
                "Deep Learning Toolbox",...
                "Statistics and Machine Learning Toolbox",...
                "Symbolic Math Toolbox"...
                ];

            installedTbxNames = matlab.addons.installedAddons().Name;
            testCase.verifyThat(installedTbxNames, IsSupersetOf(expectedTbxNames));
        end
    end
end
